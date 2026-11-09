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
    /// A sound packet (AudioPacket), on the link's queue.
    var onAudio: ((AudioPacket.Packet) -> Void)?

    private let connection: NWConnection
    private let cipher: DatagramCipher
    /// The sound's datagrams: same session, their own key, stream id and replay window.
    private let audioCipher: DatagramCipher
    private let assembler = FrameAssembler()
    private let queue = DispatchQueue(label: "couchpad.video")
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var wanted = false
    private var lastFrameAt: Date?
    private var stalled = false
    /// Frames are arriving over UDP (one in the last two seconds).
    private(set) var isLive = false

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, sessionKey: SymmetricKey) {
        cipher = DatagramCipher(sessionKey: sessionKey, isHost: false)
        audioCipher = DatagramCipher(sessionKey: sessionKey, isHost: false, keyInfo: AudioPacket.keyInfo, idInfo: AudioPacket.idInfo)
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        connection = NWConnection(host: host, port: port, using: params)
    }

    func start() {
        connection.start(queue: queue)
        receive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: .milliseconds(10), leeway: .milliseconds(2))
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
            self.ticks = 0
        }
    }

    func ack(_ pts: UInt64) {
        queue.async { self.send(VideoDatagram.ack(pts)) }
    }

    private func tick() {
        ticks += 1
        if wanted, ticks % 100 == 0 { sendHello() }
        deliver(assembler.tick())
        if let last = lastFrameAt, Date().timeIntervalSince(last) > 2 {
            isLive = false
            if !stalled { stalled = true; onStall?() }
        }
    }

    private func deliver(_ delivery: FrameAssembler.Delivery) {
        for nack in delivery.nacks { send(VideoDatagram.nack(sequence: nack.sequence, missing: nack.missing)) }
        let loss = assembler.takeLoss()
        if loss.frames > 0 { onLoss?(loss.frames, loss.chunks) }
        for frame in delivery.frames { onFrame?(frame) }
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
                if first == VideoDatagram.MessageType.chunk.rawValue { self.deliver(self.assembler.add(plain)) }
            } else if let data, data.prefix(8) == self.audioCipher.streamID, let plain = self.audioCipher.open(data),
                      plain.first == AudioPacket.datagramType, let packet = AudioPacket.decode(plain) {
                // Sound says nothing about the picture's path: it never counts as a sign of life
                // for the fallback to TCP, which is the picture's alone.
                self.onAudio?(packet)
            }
            if error == nil { self.receive() }
        }
    }
}
