import CryptoKit
import Foundation
import Network

/// The UDP side of the screen stream (see VideoDatagram in SecureChannel.swift): tells the
/// host where to send datagrams, puts frames back together, acknowledges them, and notices
/// when the picture stops coming so the host can fall back to TCP. Runs on its own queue;
/// callbacks arrive there too.
final class VideoLink {
    /// A whole frame (a ScreenPacket), in order.
    var onFrame: ((Data) -> Void)?
    /// Frames will never complete: the decoder needs a keyframe. Carries how many frames were
    /// given up on and how many of their chunks never arrived.
    var onLoss: ((Int, Int) -> Void)?
    /// Datagrams were flowing and stopped: the host should go back to TCP.
    var onStall: (() -> Void)?

    private let connection: NWConnection
    private let cipher: DatagramCipher
    private let assembler = FrameAssembler()
    private let queue = DispatchQueue(label: "couchpad.video")
    private var timer: DispatchSourceTimer?
    private var wanted = false
    private var lastFrameAt: Date?
    private var stalled = false
    /// Frames are arriving over UDP (one in the last two seconds).
    private(set) var isLive = false

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, sessionKey: SymmetricKey) {
        cipher = DatagramCipher(sessionKey: sessionKey, isHost: false)
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        connection = NWConnection(host: host, port: port, using: params)
    }

    func start() {
        connection.start(queue: queue)
        receive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func cancel() {
        timer?.cancel()
        connection.cancel()
    }

    /// Whether the phone wants the picture right now; hellos only go out while it does.
    func setWanted(_ wanted: Bool) {
        queue.async {
            self.wanted = wanted
            if wanted { self.sendHello() } else { self.assembler.reset(); self.isLive = false; self.lastFrameAt = nil }
        }
    }

    func ack(_ pts: UInt64) {
        queue.async { self.send(VideoDatagram.ack(pts)) }
    }

    private func tick() {
        if wanted { sendHello() }
        if assembler.expire() { reportLoss() }
        if let last = lastFrameAt, Date().timeIntervalSince(last) > 2 {
            isLive = false
            if !stalled { stalled = true; onStall?() }
        }
    }

    private func reportLoss() {
        let loss = assembler.takeLoss()
        onLoss?(loss.frames, loss.chunks)
    }

    private func sendHello() {
        guard connection.state == .ready else { return }
        send(VideoDatagram.hello)
    }

    private func send(_ plain: Data) {
        guard connection.state == .ready, let sealed = cipher.seal(plain) else { return }
        connection.send(content: sealed, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let plain = self.cipher.open(data), let first = plain.first {
                // Anything authentic from the host, a frame chunk or a ping, means the path is alive.
                self.lastFrameAt = Date()
                self.isLive = true
                self.stalled = false
                if first == VideoDatagram.MessageType.chunk.rawValue, let (frame, lostBefore) = self.assembler.add(plain) {
                    if lostBefore { self.reportLoss() }
                    self.onFrame?(frame)
                }
            }
            if error == nil { self.receive() }
        }
    }
}
