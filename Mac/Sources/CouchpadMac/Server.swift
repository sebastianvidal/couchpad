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
        /// The size and rate this phone asked for; the stream serves the largest of them all.
        var screenRequest = (maxWidth: 0, maxHeight: 0, fps: 0)
        /// The desktop this phone would like when the Mac has no screen of its own (`v d`, in
        /// points), and when it said so: the latest sender's shape wins. Nil from old phones.
        var desk: (size: VirtualScreen.Size, at: CFAbsoluteTime)?
        var inflight = 0
        var needsKeyframe = true
        /// Frames sent but not yet acknowledged by the phone (`v a <pts>`), oldest first:
        /// the true backlog, including what sits in the kernel and on the air.
        var unacked: [(pts: UInt64, bytes: Int, sentAt: CFAbsoluteTime)] = []
        var acks = false
        /// When the last ack arrived and the last frame went out: a phone that keeps getting
        /// frames but has stopped answering is gone (its connection died without a close),
        /// and must not hold the capture back or be fed any longer.
        var lastAckAt = 0.0
        var lastFrameSentAt = 0.0
        var ackDelay = 0.0
        /// Worst ack delay since the last stats line: stalls are short and the average hides them.
        var maxAckDelay = 0.0
        /// Video over UDP: the datagram cipher for this session and, once the phone has sent
        /// a hello, the UDP flow to send frames down. Nil means frames go over TCP.
        var video: DatagramCipher?
        var udp: NWConnection?
        var videoSequence: UInt32 = 0
        var lastDatagramAt = 0.0
        /// The last few frames' chunk plaintexts, to answer nacks from.
        var recentChunks: [(sequence: UInt32, chunks: [Data])] = []
        var resent = 0
        var lossReports = 0
        var lossTotal = 0   // never reset; the health check diffs it
        var lostChunks = 0
        /// Sound: whether this phone asked for it (`v s 1`; only with the picture on), its own
        /// datagram stream (key, id and counter apart from the picture's), packets sent and
        /// skipped in the stats window, when recent packets went out (to work out the round
        /// trip from the phone's echo), its reports summed over the window, the latest one,
        /// and the smoothed round trip.
        var wantsSound = false
        var audio: DatagramCipher?
        var audioSent = 0
        var audioSkipped = 0
        var audioSentAt: [(sequence: UInt32, at: CFAbsoluteTime)] = []
        var audioWindow = AudioPacket.Report()
        var audioReport: AudioPacket.Report?
        var audioRTT: Double?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private enum ProtocolError: Error { case badHandshake, badFrame }

    private var listener: NWListener?
    private var udpListener: NWListener?
    private var keepalive: DispatchSourceTimer?
    private var sendErrors = 0
    /// Authenticated sessions by video stream id, for matching incoming datagrams.
    private var videoSessions: [Data: Session] = [:]
    /// Data chunks per parity chunk right now: fewer while frames are getting lost.
    private var fecGroup = VideoDatagram.groupSize
    private var lastLossAt = 0.0
    private var lastFecCutAt = 0.0
    private var lastFecRelaxAt = 0.0
    /// Spreads each phone's datagrams over time on its own real-time thread (see Pacer).
    private lazy var pacer = Pacer(onSendError: { [weak self] in self?.queue.async { self?.sendErrors += 1 } })
    private let port: UInt16
    // User-interactive: acks, the 1 ms pacer and key injection must keep their turn while
    // a fullscreen game pins every core. At default priority the pacer fell behind and
    // released datagrams late and in bursts, which the Wi-Fi then dropped.
    private let queue = DispatchQueue(label: "couchpad.server", qos: .userInteractive)
    private let onChange: () -> Void
    private var sessions: [ObjectIdentifier: Session] = [:]

    private(set) var status = "Starting…"
    /// Once a second while a phone has the picture: worst ack delay, frames lost, captures
    /// skipped, as a short line for the menu, and whether that counts as healthy.
    private(set) var healthLine: String?
    private(set) var healthy = true
    private var tick = 0
    private var lastEncodedTotal = 0
    private var lastSkippedTotal = 0
    private var lastLossTotals: [ObjectIdentifier: Int] = [:]
    private var skipStormTicks = 0
    private var lastStreamStartAt = 0.0
    private var syncPending = false
    /// The last couple of sound packets, newest first: copies ride along in each datagram.
    private var recentAudio: [AudioPacket.Packet] = []

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
        ScreenStreamer.shared.onAudio = { [weak self] packet in
            self?.queue.async { self?.broadcastAudio(packet) }
        }
        ScreenStreamer.shared.isCongested = { [weak self] in
            // Called on the encoder's queue; a stale read is harmless here.
            guard let self else { return false }
            let now = CFAbsoluteTimeGetCurrent()
            return self.sessions.values.contains { session in
                guard session.wantsScreen, session.authenticated else { return false }
                guard session.acks else { return session.inflight > self.inflightCap }
                // A phone that has answered nothing for a second is gone or blacked out; it
                // must not stall the picture for the others (it is dropped shortly, below).
                guard now - session.lastAckAt < 1 else { return false }
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
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            // A phone that vanishes mid-stream (Wi-Fi reset, app killed) sends no close; without
            // keepalives its session would linger for minutes, still being fed frames.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 2
            tcp.keepaliveCount = 3
        }
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
                // Frames going out, nothing coming back for seconds: the phone is gone. Its
                // old session would otherwise be a ghost client, fed every frame and never
                // answering, which looks to the capture like a hopelessly late phone.
                for session in self.sessions.values
                where session.wantsScreen && session.acks && now - session.lastFrameSentAt < 2 && now - session.lastAckAt > 4 {
                    NSLog("Screen %@: no acks for 4 s while sending; dropping the dead session", String(describing: session.connection.endpoint))
                    self.drop(session)
                }
                self.tick += 1
                if self.tick % 2 == 0 { self.checkHealth(now: now) }
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
        case .nack:
            guard plain.count >= 7, let video = session.video else { return }
            let sequence = UInt32(VideoDatagram.readUInt(plain, 1, bytes: 4))
            let n = Int(VideoDatagram.readUInt(plain, 5, bytes: 2))
            guard plain.count >= 7 + 2 * n, let frame = session.recentChunks.first(where: { $0.sequence == sequence }) else { return }
            let wanted = n == 0 ? Array(frame.chunks.indices) : (0..<n).map { Int(VideoDatagram.readUInt(plain, 7 + 2 * $0, bytes: 2)) }
            // Resends go to the front of the queue: the phone is holding frames for them.
            let again = wanted.filter { $0 < frame.chunks.count }.compactMap { video.seal(frame.chunks[$0]) }
            if let udp = session.udp { pacer.enqueue(again, for: ObjectIdentifier(session), udp: udp, front: true) }
            session.resent += again.count
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
            session.audio = DatagramCipher(sessionKey: key, isHost: true, keyInfo: AudioPacket.keyInfo, idInfo: AudioPacket.idInfo)
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
            // Every address this Mac has, so the phone can still reach it away from home (VPN).
            let addresses = HostAddresses.ipv4()
            if !addresses.isEmpty { try send("addrs \(port) \(addresses.joined(separator: " "))", to: session) }
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
    /// `v s 1` / `v s 0` switch sound on or off, `v s r …` is the phone's report on it.
    /// `v d <width> <height>` is the desktop, in points, the phone would like the Mac to have
    /// when the phone is its only screen (VirtualScreen); sent before the first `v 1` and
    /// whenever the picture's pane changes shape.
    private func handleScreenCommand(_ line: String, session: Session) {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "1":
            guard parts.count >= 5, let w = Int(parts[2]), let h = Int(parts[3]), let fps = Int(parts[4]), w > 0, h > 0 else { return }
            session.wantsScreen = true
            session.screenRequest = (w, h, fps)
            NSLog("Screen %@: wants %dx%d at %d fps", String(describing: session.connection.endpoint), w, h, fps)
            session.needsKeyframe = true
            session.unacked.removeAll()
            syncScreen()
            syncSound()
        case "0":
            session.wantsScreen = false
            syncScreen()
            syncSound()
        case "s":
            guard parts.count >= 3 else { return }
            switch parts[2] {
            case "1", "0":
                let on = parts[2] == "1"
                if on, !session.wantsSound {
                    // A fresh start: the last report and round trip are from before.
                    session.audioReport = nil
                    session.audioRTT = nil
                    session.audioWindow = AudioPacket.Report()
                }
                session.wantsSound = on
                syncSound()
            case "r":
                guard let report = AudioPacket.parseReport(line) else { return }
                noteAudioReport(report, session: session)
            default:
                break
            }
        case "d":
            guard parts.count >= 4, let w = Int(parts[2]), let h = Int(parts[3]), (1...10_000).contains(w), (1...10_000).contains(h) else { return }
            session.desk = (VirtualScreen.Size(width: w, height: h), CFAbsoluteTimeGetCurrent())
            NSLog("Screen %@: wants a %dx%d desktop with no screen of its own", String(describing: session.connection.endpoint), w, h)
            syncDesk()
        case "k":
            session.needsKeyframe = true
            ScreenStreamer.shared.requestKeyframe()
        case "l":
            // The phone gave up on frames over UDP: resync, send more parity, and ease off
            // the bitrate so the next loss is less likely.
            let frames = Int(parts.count > 2 ? parts[2] : "1") ?? 1
            session.lossReports += frames
            session.lossTotal += frames
            session.lostChunks += Int(parts.count > 3 ? parts[3] : "0") ?? 0
            session.needsKeyframe = true
            ScreenStreamer.shared.requestKeyframe()
            ScreenStreamer.shared.noteLoss(frames: max(1, frames))
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastFecCutAt > 0.5 { fecGroup = max(3, fecGroup - 1); lastFecCutAt = now }
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
        session.lastAckAt = now
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

    /// Sums the phone's report into the stats window and works out the round trip from its
    /// echo: when the echoed packet went out, less how long the phone held it before reporting.
    private func noteAudioReport(_ report: AudioPacket.Report, session: Session) {
        session.audioWindow.received += report.received
        session.audioWindow.late += report.late
        session.audioWindow.lost += report.lost
        session.audioWindow.recovered += report.recovered
        session.audioWindow.trimmed += report.trimmed
        session.audioWindow.underruns += report.underruns
        session.audioReport = report
        guard let sent = session.audioSentAt.last(where: { $0.sequence == report.echoSequence }) else { return }
        let rtt = max(0, CFAbsoluteTimeGetCurrent() - sent.at - Double(report.echoHeldMicros) / 1_000_000)
        session.audioRTT = session.audioRTT.map { $0 * 0.7 + rtt * 0.3 } ?? rtt
    }

    private var lastStatsAt = 0.0
    /// Once in a while, how far behind the phone is: handy when latency feels off.
    private func logScreenStats(_ session: Session, now: CFAbsoluteTime) {
        guard now - lastStatsAt > 5 else { return }
        lastStatsAt = now
        let backlog = session.unacked.reduce(0) { $0 + $1.bytes }
        NSLog("Screen %@ (%@): ack delay %.0f ms (max %.0f), backlog %d KB in %d frames, %d resent, %d lost (%d chunks), parity 1/%d, pacer gap %.0f ms; %@",
              String(describing: session.connection.endpoint), session.udp == nil ? "tcp" : "udp", session.ackDelay * 1000, session.maxAckDelay * 1000,
              backlog / 1024, session.unacked.count, session.resent, session.lossReports, session.lostChunks, fecGroup, pacer.report() * 1000,
              ScreenStreamer.shared.takeStats() + audioStats(session))
        session.maxAckDelay = 0
        session.audioSent = 0
        session.audioSkipped = 0
        session.audioWindow = AudioPacket.Report()
        session.lossReports = 0
        session.lostChunks = 0
        session.resent = 0
    }

    /// The sound's part of the stats line, while this phone has it on: what went out, what
    /// the phone made of it (summed over the window), its buffer and output delay (latest
    /// report), and the estimated latency from capture to speaker.
    private func audioStats(_ session: Session) -> String {
        guard session.wantsScreen, session.wantsSound else { return "" }
        let window = session.audioWindow
        let latest = session.audioReport ?? AudioPacket.Report()
        let age = ScreenStreamer.shared.audioAge * 1000
        let rtt = (session.audioRTT ?? 0) * 1000
        let latency = age + rtt / 2 + Double(latest.bufferMs) + Double(latest.outputMs)
        let skipped = session.audioSkipped > 0 ? ", \(session.audioSkipped) skipped" : ""
        return "; audio \(session.audioSent) sent (\(session.udp == nil ? "tcp" : "udp")\(skipped)), age \(Int(age.rounded())) ms, "
            + "phone \(window.late) late, \(window.lost) lost (\(window.recovered) recovered), \(window.trimmed) trimmed, \(window.underruns) underruns, "
            + "buffer \(latest.bufferMs)/\(latest.targetMs) ms, out \(latest.outputMs) ms, rtt \(Int(rtt.rounded())) ms, "
            + "latency ~\(Int(latency.rounded())) ms, sound \(latest.skewMs) ms behind picture"
    }

    /// Once a second: summarise the stream for the menu and the phones, and act on the one
    /// failure pattern that cannot fix itself. Captures skipped while nothing is lost means
    /// the host is waiting on acks that never come (a ghost session, a stuck backlog): after
    /// three such seconds the silent sessions are dropped, every backlog is cleared and a
    /// keyframe is forced, so a new cause of that pattern costs seconds, not the session.
    private func checkHealth(now: CFAbsoluteTime) {
        let streamer = ScreenStreamer.shared
        let encoded = streamer.encodedTotal - lastEncodedTotal
        let skipped = streamer.skippedTotal - lastSkippedTotal
        lastEncodedTotal = streamer.encodedTotal
        lastSkippedTotal = streamer.skippedTotal
        let watching = sessions.values.filter { $0.wantsScreen && $0.authenticated }
        var lost = 0
        var totals: [ObjectIdentifier: Int] = [:]
        for session in watching {
            let id = ObjectIdentifier(session)
            totals[id] = session.lossTotal
            lost += session.lossTotal - (lastLossTotals[id] ?? session.lossTotal)
        }
        lastLossTotals = totals
        guard !watching.isEmpty else {
            if healthLine != nil { healthLine = nil; healthy = true; skipStormTicks = 0; report() }
            return
        }
        let ackMs = Int((watching.filter { $0.acks && now - $0.lastAckAt < 5 }.map(\.ackDelay).max() ?? 0) * 1000)
        let skipPct = encoded + skipped > 0 ? skipped * 100 / (encoded + skipped) : 0
        let storm = skipped > 20 && encoded < 5
        let ok = ackMs <= 50 && lost < 2 && !storm
        let phones = sessions.values.filter { $0.authenticated }.count
        let line = String(format: "%d ms · %d lost/s · %d%% skipped", ackMs, lost, skipPct)
        for session in watching { try? send("screen health \(ok ? 1 : 0) \(ackMs) \(lost) \(skipPct) \(phones)", to: session) }
        if line != healthLine || ok != healthy {
            healthLine = line
            healthy = ok
            report()
        }
        skipStormTicks = storm ? skipStormTicks + 1 : 0
        if skipStormTicks >= 3 {
            skipStormTicks = 0
            NSLog("Watchdog: skip storm (%d skipped, %d encoded in the last second, %d lost); dropping silent sessions and clearing backlogs", skipped, encoded, lost)
            for session in watching where session.acks && now - session.lastAckAt > 1 { drop(session) }
            for session in sessions.values {
                session.unacked.removeAll()
                session.needsKeyframe = true
            }
            streamer.requestKeyframe()
        }
    }

    /// One stream serves every phone, at the largest size any of them asked for: each
    /// phone's picture is letterboxed anyway, and taking the latest request instead would
    /// have two phones with different panes restart the stream at each other's size, over
    /// and over (every restart costs an encoder and a keyframe). Stops when nobody wants it.
    /// Requests arriving within 300 ms of the last (re)start are coalesced into one: a phone
    /// rotating or folding sends several sizes in a row, and each restart costs a keyframe.
    private func syncScreen() {
        syncDesk()
        let wanting = sessions.values.filter { $0.wantsScreen }
        guard !wanting.isEmpty else { ScreenStreamer.shared.stop(); return }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastStreamStartAt < 0.3 {
            guard !syncPending else { return }
            syncPending = true
            queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.syncPending = false
                self?.syncScreen()
            }
            return
        }
        lastStreamStartAt = now
        ScreenStreamer.shared.start(maxWidth: wanting.map(\.screenRequest.maxWidth).max() ?? 0,
                                    maxHeight: wanting.map(\.screenRequest.maxHeight).max() ?? 0,
                                    fps: wanting.map(\.screenRequest.fps).max() ?? 0)
    }

    /// The desktop shape for a Mac with no screen of its own: the one most recently sent by a
    /// phone with the picture on, or none (the legacy virtual screen) if none of them sent one.
    /// The streamer ignores a repeat, and waits for a new one to hold still before reshaping.
    private func syncDesk() {
        let desk = sessions.values.filter { $0.wantsScreen }.compactMap(\.desk).max { $0.at < $1.at }
        ScreenStreamer.shared.setDesk(desk?.size)
    }

    /// Sound is captured only while some phone with the picture wants it.
    private func syncSound() {
        ScreenStreamer.shared.setSoundWanted(sessions.values.contains { $0.authenticated && $0.wantsScreen && $0.wantsSound })
    }

    /// Sends a sound packet to every phone that wants it. Over UDP, straight out on the
    /// sound's own datagram stream, with copies of the packets just before it; it never goes
    /// through the pacer, where it would wait behind a keyframe's datagrams. Over TCP, one
    /// packet a message, skipped (not queued) while the phone is that far behind, like frames.
    /// Sound never touches the picture's acks, backlog, pacing or parity.
    private func broadcastAudio(_ packet: AudioPacket.Packet) {
        let previous = recentAudio
        recentAudio.insert(packet, at: 0)
        if recentAudio.count > AudioRedundancy.maxCopies { recentAudio.removeLast(recentAudio.count - AudioRedundancy.maxCopies) }
        let listeners = sessions.values.filter { $0.authenticated && $0.wantsScreen && $0.wantsSound }
        guard !listeners.isEmpty else { return }
        var datagram: Data?
        var message: Data?
        let now = CFAbsoluteTimeGetCurrent()
        for session in listeners {
            if let udp = session.udp, let audio = session.audio {
                if datagram == nil {
                    var bundled = packet
                    bundled.payloads = AudioRedundancy.payloads(newest: packet, previous: previous)
                    datagram = AudioPacket.datagram(bundled)
                }
                guard let plain = datagram, let sealed = audio.seal(plain) else { continue }
                udp.send(content: sealed, completion: .contentProcessed { _ in })
            } else {
                guard session.inflight <= inflightCap else { session.audioSkipped += 1; continue }
                if message == nil { message = AudioPacket.message(packet) }
                guard let plain = message, let cipher = session.send, let sealed = try? cipher.seal(plain) else { continue }
                session.inflight += sealed.count
                let size = sealed.count
                session.connection.send(content: sealed, completion: .contentProcessed { [weak self, weak session] _ in
                    self?.queue.async { session?.inflight -= size }
                })
            }
            session.audioSent += 1
            session.audioSentAt.append((packet.sequence, now))
            if session.audioSentAt.count > 350 { session.audioSentAt.removeFirst(session.audioSentAt.count - 300) }
        }
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
                pacer.bytesPerSecond = ScreenStreamer.shared.paceBytesPerSecond
                pacer.enqueue(chunks.compactMap { video.seal($0) }, for: ObjectIdentifier(session), udp: udp)
                session.recentChunks.append((session.videoSequence &- 1, chunks))
                if session.recentChunks.count > 8 { session.recentChunks.removeFirst() }
                session.lastFrameSentAt = now
                session.unacked.append((frame.presentationMicros, packet.count, now))
                if session.unacked.count > 600 { session.unacked.removeFirst(300) }
                continue
            }
            guard let cipher = session.send, let sealed = try? cipher.seal(packet) else { continue }
            session.inflight += sealed.count
            session.lastFrameSentAt = now
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
        pacer.clear(ObjectIdentifier(session))
        // Never leave a key or mouse button stuck down when the phone goes away.
        if session.authenticated { Injector.shared.releaseAll() }
        session.wantsScreen = false
        session.wantsSound = false
        syncScreen()
        syncSound()
        report()
    }

    private func report() {
        let n = sessions.values.filter { $0.authenticated }.count
        var line = n == 0 ? "Waiting for iPhone…" : (n == 1 ? "1 iPhone connected" : "\(n) iPhones connected")
        if let healthLine { line += " · " + healthLine }
        if !healthy { line += " — picture struggling" }
        set(status: line)
    }

    private func set(status: String) {
        self.status = status
        onChange()
    }
}
