import CryptoKit
import Foundation
import Network
import Combine

let servicePort: UInt16 = 48123

/// Finds computers running Couchpad over Bonjour, keeps one TCP connection open, runs the
/// protocol v2 handshake (see SecureChannel.swift) so every line is encrypted, and handles
/// pairing: the phone proves it holds a token (or the pairing code) with an HMAC over the
/// handshake transcript, and the host proves the same back. Tokens are kept per host so the
/// code is only needed once.
///
/// Session rules:
/// - Leaving the app closes the connection cleanly (the host then releases any held keys).
/// - Returning reconnects at once with the stored token; discovery is restarted too, since
///   Bonjour results go stale while the app is suspended.
/// - Transient failures retry with backoff and never touch the token. The pairing prompt only
///   appears when the host explicitly refuses the token or there is none.
@MainActor
final class Client: ObservableObject {
    struct Service: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    enum Phase: Equatable {
        case searching, connecting, needsCode, wrongCode, paired, disconnected
    }

    enum HostPlatform { case mac, windows }

    @Published private(set) var services: [Service] = []
    @Published private(set) var status = "Looking for your computer…"
    @Published private(set) var phase: Phase = .searching
    @Published private(set) var macName = ""
    @Published private(set) var hostPlatform: HostPlatform = .mac

    /// Binary messages from the host (the screen stream), delivered on the main actor.
    var onScreenPacket: ((Data) -> Void)?
    /// Text status about the screen stream from the host ("denied", "error …").
    var onScreenStatus: ((String) -> Void)?
    /// `screen health <ok> <ack ms> <lost/s> <skipped %> <phones>`, once a second from the host.
    var onScreenHealth: ((ScreenHealth) -> Void)?
    /// A frame was lost on the UDP path: the decoder must wait for the next keyframe.
    var onScreenLoss: (() -> Void)?
    /// The Mac's sound, with the picture (see AudioPacket). Packets go straight to it from
    /// whichever queue they arrive on.
    let audio = AudioPlayer()

    /// "Mac" or "PC", for UI text about the paired computer.
    var hostNoun: String { hostPlatform == .windows ? "PC" : "Mac" }
    var isConnected: Bool { phase == .paired }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiving = false
    private var buffer = FrameBuffer()
    private var privateKey = P256.KeyAgreement.PrivateKey()
    private var transcript = Data()
    private var sendCipher: FrameCipher?
    private var recvCipher: FrameCipher?
    private var sessionKey: SymmetricKey?
    /// Frames over UDP once paired (see VideoLink); nil while the host's address is unknown.
    private var videoLink: VideoLink?
    private var screenWanted = false
    /// Sends the player's report once a second while it plays.
    private var audioReports: Task<Void, Never>?
    private var sentCredential: Credential?
    private var pendingCode: String?
    private var retryTask: Task<Void, Never>?
    private var failures = 0
    private var inBackground = false
    private var preferredName: String?
    private var manualHost: String?
    private let queue = DispatchQueue(label: "couchpad.client")
    private let defaults = UserDefaults.standard

    private enum Credential { case token(String), code(String) }

    // MARK: Lifecycle

    func startBrowsing() {
        guard browser == nil else { return }
        preferredName = defaults.string(forKey: "preferredHost")
        restartBrowser()
        // Bonjour only calls back when it finds something, so give it a moment and then try
        // the stored address if there is still nothing.
        scheduleRetry(after: 2)
    }

    func appDidEnterBackground() {
        inBackground = true
        retryTask?.cancel()
        // A clean close: the host sees the FIN right away instead of a dead socket later.
        if let connection {
            connection.cancel()
            self.connection = nil
        }
        videoLink?.cancel()
        videoLink = nil
        stopSound()
        phase = .disconnected
        status = "Paused"
    }

    func appDidBecomeActive() {
        guard inBackground else { return }
        inBackground = false
        failures = 0
        restartBrowser()
        if let manualHost {
            connect(host: manualHost)
        } else {
            autoConnect()
        }
    }

    private func restartBrowser() {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: "_couchpad._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { result -> Service? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Service(id: name, name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                self?.services = list
                self?.autoConnect()
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    // MARK: Connecting

    private func autoConnect() {
        guard connection == nil, !inBackground, manualHost == nil else { return }
        if services.isEmpty {
            // Bonjour found nothing (yet, or blocked): fall back to the address a QR pairing gave us.
            if let name = preferredName, let addr = defaults.string(forKey: addressKey(name)) {
                connect(endpoint: .hostPort(host: NWEndpoint.Host(addr), port: NWEndpoint.Port(rawValue: servicePort)!), name: name)
            }
            return
        }
        // The host we used last, then any host we have paired with, then whatever is there.
        let service = services.first { $0.name == preferredName }
            ?? services.first { token(for: $0.name) != nil }
            ?? services[0]
        connect(to: service)
    }

    func connect(to service: Service) {
        manualHost = nil
        connect(endpoint: service.endpoint, name: service.name)
    }

    func connect(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        manualHost = trimmed
        connect(endpoint: .hostPort(host: NWEndpoint.Host(trimmed), port: NWEndpoint.Port(rawValue: servicePort)!), name: trimmed)
    }

    private func connect(endpoint: NWEndpoint, name: String) {
        retryTask?.cancel()
        connection?.cancel()
        videoLink?.cancel()
        videoLink = nil
        audio.reset()   // whatever is queued belongs to the old session
        receiving = false
        buffer = FrameBuffer()
        privateKey = P256.KeyAgreement.PrivateKey()
        sendCipher = nil
        recvCipher = nil
        sentCredential = nil
        macName = name
        phase = .connecting
        status = failures == 0 ? "Connecting to \(name)…" : "Reconnecting to \(name)…"

        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        // Voice class: the input lines are tiny and latency-critical, and an active
        // voice-class connection makes iOS hold off Wi-Fi roaming scans, which otherwise
        // black the radio out for most of a second at a time (and freeze the picture).
        params.serviceClass = .interactiveVoice
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.connectionTimeout = 5
        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                switch state {
                case .ready:
                    self.failures = 0
                    guard !self.receiving else { return } // the path recovered; the session is already set up
                    self.receiving = true
                    self.receive(on: connection)
                    // Handshake: our ephemeral public key, in the clear. Secrets come later, encrypted.
                    let hello = "v2 \(self.privateKey.publicKey.rawRepresentation.base64EncodedString())\n"
                    connection.send(content: Data(hello.utf8), completion: .contentProcessed { _ in })
                case .waiting(let error):
                    // No route yet (Wi-Fi coming back, host restarting). Give it a moment, then retry fresh.
                    self.phase = .connecting
                    self.status = "Can't reach \(name): \(error.localizedDescription)"
                    self.scheduleRetry(after: 3)
                case .failed, .cancelled:
                    self.connection = nil
                    self.receiving = false
                    if !self.inBackground {
                        if self.phase != .wrongCode && self.phase != .needsCode { self.phase = .disconnected }
                        if self.phase == .disconnected { self.status = "Disconnected from \(name)" }
                        self.failures += 1
                        self.scheduleRetry(after: min(Double(self.failures), 5))
                    }
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        self.connection = connection
    }

    private func scheduleRetry(after seconds: Double) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.inBackground else { return }
            if let connection = self.connection, connection.state == .ready { return }
            self.connection?.cancel()
            self.connection = nil
            if let manualHost = self.manualHost {
                self.connect(host: manualHost)
            } else {
                self.autoConnect()
            }
        }
    }

    // MARK: Handshake and pairing

    /// The host answered our key with its own: derive the session and authenticate inside it.
    private func completeHandshake(_ line: String) throws {
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "v2",
              let hostKey = Data(base64Encoded: String(parts[1])), hostKey.count == 64,
              let nonce = Data(base64Encoded: String(parts[2])), nonce.count == 16 else {
            throw CryptoKitError.incorrectParameterSize
        }
        let key = try SecureChannel.sessionKey(privateKey: privateKey, peerPublicKey: hostKey, nonce: nonce)
        transcript = SecureChannel.transcript(clientKey: privateKey.publicKey.rawRepresentation, hostKey: hostKey, nonce: nonce)
        sendCipher = FrameCipher(key: key, direction: 0)
        recvCipher = FrameCipher(key: key, direction: 1)
        sessionKey = key

        if let code = pendingCode {
            pendingCode = nil
            authenticate(.code(code))
        } else if let token = token(for: macName) {
            authenticate(.token(token))
        } else if phase != .wrongCode {
            // (After a wrong code the host hangs up and we reconnect; keep that message.)
            phase = .needsCode
            status = "Enter the code shown on \(macName)"
        }
    }

    private func authenticate(_ credential: Credential) {
        sentCredential = credential
        let kind: String, secret: String
        switch credential {
        case .token(let t): kind = "token"; secret = t; status = "Connecting to \(macName)…"
        case .code(let c): kind = "code"; secret = c; status = "Pairing with \(macName)…"
        }
        phase = .connecting
        let proof = SecureChannel.proof(secret: secret, transcript: transcript, side: SecureChannel.clientTag)
        sendLine("auth \(kind) \(proof.base64EncodedString())")
    }

    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if sendCipher != nil, connection != nil {
            authenticate(.code(trimmed))
        } else {
            // The host hung up after a wrong guess; pair on the next connection.
            pendingCode = trimmed
            phase = .connecting
            scheduleRetry(after: 0.1)
        }
    }

    /// Pairs from a scanned or opened `couchpad://pair?name=&addr=&port=&code=` URL.
    /// Connects straight to the address, so this works even where Bonjour is blocked.
    @discardableResult
    func pair(using url: URL) -> Bool {
        guard url.scheme == "couchpad", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard let code = value("code"), !code.isEmpty else { return false }
        let port = NWEndpoint.Port(rawValue: UInt16(value("port") ?? "") ?? servicePort)!
        if let addr = value("addr"), !addr.isEmpty {
            let name = value("name") ?? addr
            defaults.set(addr, forKey: addressKey(name))
            manualHost = nil
            pendingCode = code
            connect(endpoint: .hostPort(host: NWEndpoint.Host(addr), port: port), name: name)
            return true
        }
        if let name = value("name"), let service = services.first(where: { $0.name == name }) {
            pendingCode = code
            connect(to: service)
            return true
        }
        return false
    }

    func forgetMac() {
        defaults.removeObject(forKey: tokenKey(macName))
        if preferredName == macName {
            preferredName = nil
            defaults.removeObject(forKey: "preferredHost")
        }
        connection?.cancel()
    }

    private func handle(_ line: String) {
        let parts = line.split(separator: " ")
        if parts.first == "screen", parts.count >= 7, parts[1] == "health",
           let ack = Int(parts[3]), let lost = Int(parts[4]), let skipped = Int(parts[5]), let phones = Int(parts[6]) {
            onScreenHealth?(ScreenHealth(ok: parts[2] == "1", ackMs: ack, lostPerSecond: lost, skippedPercent: skipped, phones: phones))
        } else if parts.first == "screen", parts.count >= 2 {
            onScreenStatus?(String(line.dropFirst(7)))
        } else if parts.first == "ok", parts.count >= 4, let hostProof = Data(base64Encoded: String(parts[3])) {
            let token = String(parts[1])
            // The host must prove it knows the token too; an impostor can't.
            guard SecureChannel.proofMatches(hostProof, secret: token, transcript: transcript, side: SecureChannel.hostTag) else {
                status = "\(macName) failed to prove itself; not connecting"
                connection?.cancel()
                return
            }
            defaults.set(token, forKey: tokenKey(macName))
            preferredName = macName
            defaults.set(macName, forKey: "preferredHost")
            hostPlatform = parts[2] == "windows" ? .windows : .mac
            phase = .paired
            status = "Connected to \(macName)"
            if hostPlatform == .mac { startVideoLink() }
        } else if line == "nope" {
            switch sentCredential {
            case .token:
                // The host forgot this phone; the token is genuinely dead.
                defaults.removeObject(forKey: tokenKey(macName))
                phase = .needsCode
                status = "\(macName) no longer recognizes this phone"
            case .code:
                phase = .wrongCode
                status = "Wrong or expired code. Check the pairing window on \(macName)"
            case nil:
                break
            }
            sentCredential = nil
        }
    }

    // MARK: I/O

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let data { self.buffer.append(data) }
                do {
                    if self.recvCipher == nil, let line = self.buffer.nextLine() {
                        try self.completeHandshake(line)
                    }
                    if let cipher = self.recvCipher {
                        while let body = try self.buffer.next() {
                            let plain = try cipher.openData(body)
                            if plain.first == ScreenPacket.marker {
                                guard self.isConnected else { continue }
                                if plain.count >= 2, plain[plain.startIndex + 1] == AudioPacket.messageType {
                                    if let packet = AudioPacket.decode(plain) { self.audio.receive(packet) }
                                } else {
                                    self.onScreenPacket?(plain)
                                }
                            } else {
                                self.handle(String(decoding: plain, as: UTF8.self))
                            }
                        }
                    }
                } catch {
                    self.status = "\(self.macName) isn't speaking Couchpad's protocol"
                    connection.cancel()
                    return
                }
                if isComplete || error != nil {
                    // The host closed the socket; treat it like a failure so we reconnect.
                    connection.cancel()
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    /// Input commands; dropped until pairing has succeeded.
    func send(_ line: String) {
        guard isConnected, let connection, connection.state == .ready else { return }
        if line.hasPrefix("v 1 ") { screenWanted = true; videoLink?.setWanted(true) }
        if line == "v 0" { screenWanted = false; videoLink?.setWanted(false) }
        sendLine(line)
    }

    /// Tells the host a frame arrived, over UDP when that is what carries the picture.
    func ackFrame(_ pts: UInt64) {
        if let videoLink, videoLink.isLive { videoLink.ack(pts) } else { send("v a \(pts)") }
    }

    /// Sound with the picture: tells the host (it only sends sound to a phone that has the
    /// picture on and asked for it) and starts or stops the player. Sent right after every
    /// `v 1 …` and whenever the setting changes.
    func setSound(_ on: Bool) {
        send(on ? "v s 1" : "v s 0")
        guard on, isConnected else {
            stopSound()
            return
        }
        audio.start()
        guard audioReports == nil else { return }
        // The host's stats line: what arrived, what was lost, how deep the buffer is.
        audioReports = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if let report = self.audio.takeReport() { self.send(AudioPacket.reportLine(report)) }
            }
        }
    }

    private func stopSound() {
        audio.stop()
        audioReports?.cancel()
        audioReports = nil
    }

    /// Opens the UDP sideband to the host's resolved address: the host starts sending frames
    /// as datagrams once a hello reaches it. Without one (UDP blocked, address unknown) the
    /// picture simply stays on TCP.
    private func startVideoLink() {
        videoLink?.cancel()
        videoLink = nil
        guard let connection, let key = sessionKey,
              case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint else { return }
        let link = VideoLink(host: host, port: port, sessionKey: key)
        link.onFrame = { [weak self] frame in
            Task { @MainActor in
                guard let self, self.isConnected, self.videoLink === link else { return }
                self.onScreenPacket?(frame)
            }
        }
        link.onLoss = { [weak self] frames, chunks in
            Task { @MainActor in
                guard let self, self.videoLink === link else { return }
                self.onScreenLoss?()
                self.send("v l \(frames) \(chunks)")
            }
        }
        link.onStall = { [weak self] in
            Task { @MainActor in
                guard let self, self.videoLink === link, self.screenWanted else { return }
                self.send("v t")
            }
        }
        // Straight from the link's queue: a hop through the main actor would add its layout
        // work's jitter to every packet.
        link.onAudio = { [audio] packet in audio.receive(packet) }
        link.start()
        if screenWanted { link.setWanted(true) }
        videoLink = link
    }

    private func sendLine(_ line: String) {
        guard let connection, let cipher = sendCipher, let frame = try? cipher.seal(line) else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func tokenKey(_ name: String) -> String { "token.\(name)" }
    private func addressKey(_ name: String) -> String { "addr.\(name)" }
    private func token(for name: String) -> String? { defaults.string(forKey: tokenKey(name)) }
}
