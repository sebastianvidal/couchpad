import CryptoKit
import Foundation
import Network

/// TCP listener advertised over Bonjour, speaking protocol v2 (see SecureChannel.swift): a
/// plain-text key exchange, then every line encrypted. A phone must authenticate inside the
/// channel with a proof over the transcript before any input is accepted.
final class Server {
    private final class Session {
        let connection: NWConnection
        var buffer = FrameBuffer()
        let privateKey = P256.KeyAgreement.PrivateKey()
        var transcript = Data()
        var send: FrameCipher?
        var recv: FrameCipher?
        var authenticated = false
        /// Screen streaming state: whether this phone asked for the picture, how many bytes
        /// are queued in the socket, and whether we owe it a keyframe after dropping frames.
        var wantsScreen = false
        var inflight = 0
        var needsKeyframe = true
        /// Frames sent but not yet acknowledged by the phone (`v a <pts>`), oldest first:
        /// the true backlog, including what sits in the kernel and on the air.
        var unacked: [(pts: UInt64, bytes: Int, sentAt: CFAbsoluteTime)] = []
        var acks = false
        var ackDelay = 0.0
        /// Worst ack delay since the last stats line: stalls are short and the average hides them.
        var maxAckDelay = 0.0
        /// Video over UDP: the datagram cipher for this session and, once the phone has sent
        /// a hello, the UDP flow to send frames down. Nil means frames go over TCP.
        var video: DatagramCipher?
        var udp: NWConnection?
        var videoSequence: UInt32 = 0
        var lastDatagramAt = 0.0
        var lossReports = 0
        var lostChunks = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private enum ProtocolError: Error { case badHandshake, badFrame }

    private var listener: NWListener?
    private var udpListener: NWListener?
    private var keepalive: DispatchSourceTimer?
    /// Authenticated sessions by video stream id, for matching incoming datagrams.
    private var videoSessions: [Data: Session] = [:]
    /// Data chunks per parity chunk right now: fewer while frames are getting lost.
    private var fecGroup = VideoDatagram.groupSize
    private var lastLossAt = 0.0
    private var lastFecRelaxAt = 0.0
    private let port: UInt16
    private let queue = DispatchQueue(label: "couchpad.server")
    private let onChange: () -> Void
    private var sessions: [ObjectIdentifier: Session] = [:]

    private(set) var status = "Starting…"

    /// Bytes allowed in flight per phone before frames are dropped instead of queued: queuing
    /// turns a Wi-Fi hiccup into seconds of lag, dropping turns it into a brief freeze.
    private let inflightCap = 600 * 1024
    /// How long a sent frame may go unacknowledged before the capture skips frames: a Wi-Fi
    /// hiccup then costs frames, not lag. Healthy acks come back in 10–20 ms.
    private let maxUnackedAge = 0.08

    init(port: UInt16, onChange: @escaping () -> Void) throws {
        self.port = port
        self.onChange = onChange
        ScreenStreamer.shared.onFrame = { [weak self] frame in
            self?.queue.async { self?.broadcast(frame) }
        }
        ScreenStreamer.shared.isCongested = { [weak self] in
            // Called on the encoder's queue; a stale read is harmless here.
            guard let self else { return false }
            let now = CFAbsoluteTimeGetCurrent()
            return self.sessions.values.contains { session in
                guard session.wantsScreen, session.authenticated else { return false }
                guard session.acks else { return session.inflight > self.inflightCap }
                // Congested means the phone is *late*, not that a big frame is in the air:
                // skip only once the oldest unacknowledged frame has been out too long.
                // An ack lost on the way back would otherwise block capture for good: a frame
                // unacknowledged for a second counts as answered.
                let live = session.unacked.filter { now - $0.sentAt < 1 }
                guard let oldest = live.first else { return false }
                return now - oldest.sentAt > self.maxUnackedAge || live.reduce(0) { $0 + $1.bytes } > 1_000_000
            }
        }
        ScreenStreamer.shared.onStatus = { [weak self] status in
            self?.queue.async {
                guard let self else { return }
                for session in self.sessions.values where session.wantsScreen {
                    try? self.send("screen \(status)", to: session)
                }
            }
        }
    }

    /// Starts listening; if the port is busy or the network isn't up yet, keeps retrying.
    func start() {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        // Marked like a voice call: Wi-Fi gives the frames the voice access category, and
        // iOS holds off its roaming scans (which black the radio out for most of a second)
        // while a voice-class connection is active.
        params.serviceClass = .interactiveVoice
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            set(status: "Could not create listener")
            return
        }
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: "_couchpad._tcp")
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.report()
            case .failed(let error):
                self.set(status: "Server failed: \(error.localizedDescription) — retrying…")
                listener.cancel()
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
        startUDP()
        if keepalive == nil {
            // A still screen sends no frames; a ping keeps the phone from declaring UDP dead.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                for session in self.sessions.values where session.wantsScreen && now - session.lastDatagramAt > 0.5 {
                    guard let udp = session.udp, let sealed = session.video?.seal(VideoDatagram.ping) else { continue }
                    session.lastDatagramAt = now
                    udp.send(content: sealed, completion: .contentProcessed { _ in })
                }
            }
            timer.resume()
            keepalive = timer
        }
    }

    /// The video sideband: same port, UDP. Datagrams are matched to a TCP session by their
    /// stream id and only accepted from that session's address.
    private func startUDP() {
        udpListener?.cancel()
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) else {
            NSLog("Could not listen for UDP video; frames stay on TCP")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                NSLog("UDP listener failed: %@; retrying", error.localizedDescription)
                listener.cancel()
                self?.queue.asyncAfter(deadline: .now() + 3) { self?.startUDP() }
            }
        }
        listener.newConnectionHandler = { [weak self] flow in
            guard let self else { return }
            flow.stateUpdateHandler = { [weak self, weak flow] state in
                switch state {
                case .failed, .cancelled:
                    guard let self, let flow else { return }
                    for session in self.sessions.values where session.udp === flow { session.udp = nil; session.needsKeyframe = true }
                default: break
                }
            }
            flow.start(queue: self.queue)
            self.receiveDatagrams(flow)
        }
        udpListener = listener
        listener.start(queue: queue)
    }

    private func receiveDatagrams(_ flow: NWConnection) {
        flow.receiveMessage { [weak self, weak flow] data, _, _, error in
            guard let self, let flow else { return }
            if let data { self.handleDatagram(data, from: flow) }
            if error == nil { self.receiveDatagrams(flow) } else { flow.cancel() }
        }
    }

    private func handleDatagram(_ datagram: Data, from flow: NWConnection) {
        guard let id = VideoDatagram.streamID(of: datagram), let session = videoSessions[id], session.authenticated,
              Server.host(of: flow.endpoint) == Server.host(of: session.connection.endpoint),
              let plain = session.video?.open(datagram), let first = plain.first else { return }
        switch VideoDatagram.MessageType(rawValue: first) {
        case .hello:
            if session.udp !== flow {
                NSLog("Screen %@: video over UDP", String(describing: session.connection.endpoint))
                session.udp = flow
                session.needsKeyframe = true   // the first frame down the new path must stand alone
                ScreenStreamer.shared.requestKeyframe()
            }
        case .ack:
            guard plain.count >= 9 else { return }
            acknowledge(VideoDatagram.readUInt(plain, 1, bytes: 8), session: session)
        default:
            break
        }
    }

    /// The address part of an endpoint, without the interface scope, for comparing peers.
    private static func host(of endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        return String(describing: host).split(separator: "%").first.map(String.init)
    }

    /// Drops every phone; they will have to pair again.
    func disconnectAll() {
        queue.async {
            for session in self.sessions.values { self.drop(session) }
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = Session(connection)
        sessions[ObjectIdentifier(connection)] = session
        connection.stateUpdateHandler = { [weak self, weak session] state in
            switch state {
            case .failed, .cancelled: if let session { self?.drop(session) }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(session)
    }

    private func receive(_ session: Session) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak session] data, _, isComplete, error in
            guard let self, let session else { return }
            if let data, !data.isEmpty {
                do {
                    try self.handleBytes(data, session: session)
                } catch {
                    // Not a Couchpad peer, or tampering: hang up.
                    self.drop(session)
                    return
                }
            }
            if isComplete || error != nil {
                self.drop(session)
            } else {
                self.receive(session)
            }
        }
    }

    private func handleBytes(_ data: Data, session: Session) throws {
        session.buffer.append(data)

        if session.send == nil {
            // Plain-text handshake: exactly one line, "v2 <client public key>".
            guard let line = session.buffer.nextLine() else { return }
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[0] == "v2",
                  let clientKey = Data(base64Encoded: String(parts[1])), clientKey.count == 64 else {
                throw ProtocolError.badHandshake
            }
            var nonceBytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
                throw ProtocolError.badHandshake
            }
            let nonce = Data(nonceBytes)
            let hostKey = session.privateKey.publicKey.rawRepresentation
            let key = try SecureChannel.sessionKey(privateKey: session.privateKey, peerPublicKey: clientKey, nonce: nonce)
            session.transcript = SecureChannel.transcript(clientKey: clientKey, hostKey: hostKey, nonce: nonce)
            session.send = FrameCipher(key: key, direction: 1)
            session.recv = FrameCipher(key: key, direction: 0)
            session.video = DatagramCipher(sessionKey: key, isHost: true)
            let reply = "v2 \(hostKey.base64EncodedString()) \(nonce.base64EncodedString())\n"
            session.connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
        }

        guard let recv = session.recv else { return }
        while let body = try session.buffer.next() {
            let line = try recv.open(body)
            try handleLine(line, session: session)
        }
    }

    private func handleLine(_ line: String, session: Session) throws {
        if session.authenticated {
            if line.hasPrefix("v ") {
                handleScreenCommand(line, session: session)
            } else {
                Injector.shared.handle(line)
            }
            return
        }
        // Anything before "auth" is dropped, never refused: a refusal makes the phone discard its token.
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "auth", let proof = Data(base64Encoded: String(parts[2])) else { return }
        let transcript = session.transcript
        let matches: (String) -> Bool = {
            SecureChannel.proofMatches(proof, secret: $0, transcript: transcript, side: SecureChannel.clientTag)
        }
        let token: String?
        switch parts[1] {
        case "token": token = Pairing.shared.token(where: matches)
        case "code": token = Pairing.shared.pair(codeMatches: matches)
        default: token = nil
        }
        if let token {
            session.authenticated = true
            if let video = session.video { videoSessions[video.streamID] = session }
            let hostProof = SecureChannel.proof(secret: token, transcript: transcript, side: SecureChannel.hostTag)
            try send("ok \(token) mac \(hostProof.base64EncodedString())", to: session)
            report()
        } else {
            // One guess per connection: say no, then hang up.
            let frame = try session.send!.seal("nope")
            session.connection.send(content: frame, completion: .contentProcessed { [weak self, weak session] _ in
                if let session { self?.queue.async { self?.drop(session) } }
            })
        }
    }

    private func send(_ line: String, to session: Session) throws {
        guard let cipher = session.send else { throw ProtocolError.badFrame }
        let frame = try cipher.seal(line)
        session.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: Screen streaming

    /// `v 1 <maxWidth> <maxHeight> <fps>` starts the picture, `v 0` stops it, `v k` asks for a
    /// keyframe (the phone lost sync or just came back), `v a <pts>` acknowledges a frame.
    private func handleScreenCommand(_ line: String, session: Session) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "1":
            guard parts.count >= 5, let w = Int(parts[2]), let h = Int(parts[3]), let fps = Int(parts[4]), w > 0, h > 0 else { return }
            session.wantsScreen = true
            session.needsKeyframe = true
            session.unacked.removeAll()
            ScreenStreamer.shared.start(maxWidth: w, maxHeight: h, fps: fps)
        case "0":
            session.wantsScreen = false
            stopScreenIfUnwanted()
        case "k":
            session.needsKeyframe = true
            ScreenStreamer.shared.requestKeyframe()
        case "l":
            // The phone gave up on frames over UDP: resync, send more parity, and ease off
            // the bitrate so the next loss is less likely.
            session.lossReports += Int(parts.count > 2 ? parts[2] : "1") ?? 1
            session.lostChunks += Int(parts.count > 3 ? parts[3] : "0") ?? 0
            session.needsKeyframe = true
            ScreenStreamer.shared.requestKeyframe()
            ScreenStreamer.shared.noteLoss()
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLossAt > 0.5 { fecGroup = max(2, fecGroup - 1) }
            lastLossAt = now
        case "t":
            // The phone stopped getting datagrams; back to TCP until its next hello.
            if session.udp != nil {
                NSLog("Screen %@: back to TCP", String(describing: session.connection.endpoint))
                session.udp = nil
                session.needsKeyframe = true
                ScreenStreamer.shared.requestKeyframe()
            }
        case "a":
            guard parts.count >= 3, let pts = UInt64(parts[2]) else { return }
            acknowledge(pts, session: session)
        default:
            break
        }
    }

    private func acknowledge(_ pts: UInt64, session: Session) {
        session.acks = true
        let now = CFAbsoluteTimeGetCurrent()
        while let first = session.unacked.first, first.pts <= pts {
            session.unacked.removeFirst()
            if first.pts == pts {
                let delay = now - first.sentAt
                session.ackDelay = session.ackDelay * 0.9 + delay * 0.1
                session.maxAckDelay = max(session.maxAckDelay, delay)
            }
        }
        logScreenStats(session, now: now)
    }

    private var lastStatsAt = 0.0
    /// Once in a while, how far behind the phone is: handy when latency feels off.
    private func logScreenStats(_ session: Session, now: CFAbsoluteTime) {
        guard now - lastStatsAt > 5 else { return }
        lastStatsAt = now
        let backlog = session.unacked.reduce(0) { $0 + $1.bytes }
        NSLog("Screen %@ (%@): ack delay %.0f ms (max %.0f), backlog %d KB in %d frames, %d lost (%d chunks), parity 1/%d; %@",
              String(describing: session.connection.endpoint), session.udp == nil ? "tcp" : "udp", session.ackDelay * 1000, session.maxAckDelay * 1000,
              backlog / 1024, session.unacked.count, session.lossReports, session.lostChunks, fecGroup, ScreenStreamer.shared.takeStats())
        session.maxAckDelay = 0
        session.lossReports = 0
        session.lostChunks = 0
    }

    private func stopScreenIfUnwanted() {
        if !sessions.values.contains(where: { $0.wantsScreen }) { ScreenStreamer.shared.stop() }
    }

    private func broadcast(_ frame: ScreenPacket.Frame) {
        let packet = ScreenPacket.encode(frame)
        var keyframeWanted = false
        for session in sessions.values where session.wantsScreen && session.authenticated {
            // Behind: drop this frame. A dropped frame breaks the chain, so the next one sent
            // must be a keyframe, and only a keyframe clears the backlog flag.
            if session.inflight > inflightCap || (session.needsKeyframe && !frame.keyframe) {
                session.needsKeyframe = true
                keyframeWanted = true
                continue
            }
            if frame.keyframe { session.needsKeyframe = false }
            let now = CFAbsoluteTimeGetCurrent()
            while let first = session.unacked.first, now - first.sentAt > 1 { session.unacked.removeFirst() }   // acks that never came
            if fecGroup < VideoDatagram.groupSize, now - lastLossAt > 10, now - lastFecRelaxAt > 10 {
                lastFecRelaxAt = now
                fecGroup += 1
            }
            if let udp = session.udp, let video = session.video {
                // Datagrams: lost chunks are repaired from parity or cost one frame, never a stall.
                let chunks = VideoDatagram.chunks(frame: packet, sequence: session.videoSequence, groupSize: fecGroup)
                session.videoSequence &+= 1
                session.lastDatagramAt = now
                udp.batch {
                    for chunk in chunks {
                        guard let sealed = video.seal(chunk) else { continue }
                        udp.send(content: sealed, completion: .contentProcessed { _ in })
                    }
                }
                session.unacked.append((frame.presentationMicros, packet.count, now))
                if session.unacked.count > 600 { session.unacked.removeFirst(300) }
                continue
            }
            guard let cipher = session.send, let sealed = try? cipher.seal(packet) else { continue }
            session.inflight += sealed.count
            session.unacked.append((frame.presentationMicros, sealed.count, now))
            if session.unacked.count > 600 { session.unacked.removeFirst(300) }   // a phone that never acks
            let size = sealed.count
            session.connection.send(content: sealed, completion: .contentProcessed { [weak self, weak session] _ in
                self?.queue.async { session?.inflight -= size }
            })
        }
        if keyframeWanted { ScreenStreamer.shared.requestKeyframe() }
    }

    private func drop(_ session: Session) {
        guard sessions.removeValue(forKey: ObjectIdentifier(session.connection)) != nil else { return }
        session.connection.cancel()
        if let video = session.video, videoSessions[video.streamID] === session { videoSessions[video.streamID] = nil }
        session.udp?.cancel()
        // Never leave a key or mouse button stuck down when the phone goes away.
        if session.authenticated { Injector.shared.releaseAll() }
        session.wantsScreen = false
        stopScreenIfUnwanted()
        report()
    }

    private func report() {
        let n = sessions.values.filter { $0.authenticated }.count
        set(status: n == 0 ? "Waiting for iPhone…" : (n == 1 ? "1 iPhone connected" : "\(n) iPhones connected"))
    }

    private func set(status: String) {
        self.status = status
        onChange()
    }
}
