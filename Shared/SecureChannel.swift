import CryptoKit
import Foundation

/// Couchpad wire protocol v2. Shared verbatim by the iPhone and Mac apps (symlinked into
/// both); Windows/SecureChannel.cs implements the same thing in .NET.
///
/// Handshake (plain text lines, base64 fields):
///   client → host   v2 <client P-256 public key>
///   host   → client v2 <host P-256 public key> <16-byte host nonce>
/// Both sides derive  shared = ECDH(P-256)
///                    transcript = clientKey ‖ hostKey ‖ nonce
///                    sessionKey = HKDF-SHA256(shared, salt: nonce, info: "couchpad v2 session")
/// From here every message is one frame: 4-byte big-endian length, then AES-256-GCM
/// ciphertext (12-byte nonce = direction byte ‖ 3 zero bytes ‖ 64-bit counter, 16-byte tag),
/// with the direction byte as additional authenticated data. The plaintext is a UTF-8 line
/// without the newline, or, when its first byte is 0x00, a binary message (see
/// ScreenPacket): a text line never starts with a NUL, so one byte tells them apart.
///
/// Authentication inside the channel (so secrets never travel, and a relay in the middle fails
/// because the transcript binds both sides' ephemeral keys):
///   client → host   auth token|code <base64 HMAC-SHA256(key: secret, transcript ‖ "client")>
///   host   → client ok <token> <platform> <base64 HMAC-SHA256(key: token, transcript ‖ "host")>
///                 or nope
/// A new token issued at pairing is only ever seen inside the encrypted channel.
enum SecureChannel {
    static let sessionInfo = Data("couchpad v2 session".utf8)
    static let clientTag = Data("client".utf8)
    static let hostTag = Data("host".utf8)
    /// Cap on a single frame. Lines are tiny; a video keyframe of a large display can run to
    /// a few hundred kilobytes, so the cap is set well above that.
    static let maxFrame = 8 * 1024 * 1024

    static func sessionKey(privateKey: P256.KeyAgreement.PrivateKey, peerPublicKey: Data, nonce: Data) throws -> SymmetricKey {
        let peer = try P256.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nonce, sharedInfo: sessionInfo, outputByteCount: 32)
    }

    static func transcript(clientKey: Data, hostKey: Data, nonce: Data) -> Data {
        clientKey + hostKey + nonce
    }

    /// HMAC proving knowledge of `secret` (a token or pairing code) over the transcript.
    static func proof(secret: String, transcript: Data, side: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: transcript + side, using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac)
    }

    static func proofMatches(_ proof: Data, secret: String, transcript: Data, side: Data) -> Bool {
        let expected = self.proof(secret: secret, transcript: transcript, side: side)
        // Constant-time comparison.
        guard expected.count == proof.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(expected, proof) { diff |= a ^ b }
        return diff == 0
    }
}

/// Encrypts and decrypts frames for one direction of one session.
final class FrameCipher {
    private let key: SymmetricKey
    private let direction: UInt8
    private var counter: UInt64 = 0

    /// `direction` is 0 for client→host, 1 for host→client. Each side makes one cipher for
    /// sending and one for receiving, with opposite directions.
    init(key: SymmetricKey, direction: UInt8) {
        self.key = key
        self.direction = direction
    }

    private func nonce(for counter: UInt64) -> AES.GCM.Nonce {
        var bytes = Data([direction, 0, 0, 0])
        var be = counter.bigEndian
        bytes.append(Data(bytes: &be, count: 8))
        return try! AES.GCM.Nonce(data: bytes)
    }

    /// Returns a full frame: 4-byte length prefix + sealed box (ciphertext ‖ tag).
    func seal(_ line: String) throws -> Data {
        try seal(Data(line.utf8))
    }

    /// Seals arbitrary bytes (a binary message) the same way.
    func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce(for: counter), authenticating: Data([direction]))
        counter += 1
        let body = box.ciphertext + box.tag
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Decrypts one frame body (without the length prefix). Throws on tampering or reordering.
    func open(_ body: Data) throws -> String {
        String(decoding: try openData(body), as: UTF8.self)
    }

    /// Decrypts one frame body to its raw plaintext bytes.
    func openData(_ body: Data) throws -> Data {
        guard body.count >= 16 else { throw CryptoKitError.incorrectParameterSize }
        let box = try AES.GCM.SealedBox(nonce: nonce(for: counter), ciphertext: body.prefix(body.count - 16), tag: body.suffix(16))
        let plain = try AES.GCM.open(box, using: key, authenticating: Data([direction]))
        counter += 1
        return plain
    }
}

/// Accumulates bytes and yields complete frame bodies.
struct FrameBuffer {
    private var data = Data()

    mutating func append(_ bytes: Data) { data.append(bytes) }

    /// Pops the next complete frame body, or nil if more bytes are needed. Throws if a frame
    /// claims to be absurdly large (not a Couchpad peer).
    mutating func next() throws -> Data? {
        guard data.count >= 4 else { return nil }
        let length = Int(data.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) })
        guard length <= SecureChannel.maxFrame else { throw CryptoKitError.incorrectParameterSize }
        guard data.count >= 4 + length else { return nil }
        let body = data.subdata(in: 4..<(4 + length))
        data.removeSubrange(0..<(4 + length))
        return body
    }

    /// For the plain-text handshake lines before the channel exists.
    mutating func nextLine() -> String? {
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let line = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
        data.removeSubrange(data.startIndex...newline)
        return line
    }
}

/// Binary message carrying one encoded video frame of the host's screen (host → client).
/// Layout, all integers big-endian:
///   0      0x00                      binary marker
///   1      0x01                      message type: video frame
///   2      flags                     bit 0 keyframe, bit 1 HEVC (else H.264)
///   3..4   width, 5..6 height        encoded frame size in pixels
///   7..14  presentation time         microseconds
///   15..16 parameter-set bytes (N)   0 unless this is a keyframe
///   17..   N bytes: count, then for each set a 2-byte length and the bytes (no start codes)
///   then   the frame as length-prefixed NAL units (4-byte lengths, as VideoToolbox emits)
/// The phone asks for the stream with `v 1 <maxWidth> <maxHeight> <fps>`, stops it with
/// `v 0`, asks for a fresh keyframe with `v k`, and points with `M <x> <y>` (0…1 fractions
/// of the streamed display). `screen <state>` lines from the host report why there is no
/// picture (`denied` until Screen Recording is allowed, `error <text>`).
enum ScreenPacket {
    static let marker: UInt8 = 0x00
    static let videoType: UInt8 = 0x01
    static let keyframeFlag: UInt8 = 0x01
    static let hevcFlag: UInt8 = 0x02
    static let headerSize = 17

    struct Frame {
        var keyframe: Bool
        var hevc: Bool
        var width: Int
        var height: Int
        var presentationMicros: UInt64
        var parameterSets: [Data]
        var nalData: Data
    }

    static func encode(_ frame: Frame) -> Data {
        var out = Data(capacity: headerSize + 64 + frame.nalData.count)
        out.append(marker)
        out.append(videoType)
        out.append((frame.keyframe ? keyframeFlag : 0) | (frame.hevc ? hevcFlag : 0))
        appendUInt16(&out, UInt16(clamping: frame.width))
        appendUInt16(&out, UInt16(clamping: frame.height))
        var pts = frame.presentationMicros.bigEndian
        out.append(Data(bytes: &pts, count: 8))
        var sets = Data()
        if !frame.parameterSets.isEmpty {
            sets.append(UInt8(frame.parameterSets.count))
            for set in frame.parameterSets {
                appendUInt16(&sets, UInt16(clamping: set.count))
                sets.append(set)
            }
        }
        appendUInt16(&out, UInt16(clamping: sets.count))
        out.append(sets)
        out.append(frame.nalData)
        return out
    }

    static func decode(_ data: Data) -> Frame? {
        guard data.count >= headerSize, data[data.startIndex] == marker, data[data.startIndex + 1] == videoType else { return nil }
        let b = data.startIndex
        let flags = data[b + 2]
        let width = Int(readUInt16(data, b + 3)), height = Int(readUInt16(data, b + 5))
        var pts: UInt64 = 0
        for i in 0..<8 { pts = (pts << 8) | UInt64(data[b + 7 + i]) }
        let setsLength = Int(readUInt16(data, b + 15))
        guard data.count >= headerSize + setsLength else { return nil }
        var sets: [Data] = []
        if setsLength > 0 {
            var i = b + headerSize
            let end = i + setsLength
            let count = Int(data[i]); i += 1
            for _ in 0..<count {
                guard i + 2 <= end else { return nil }
                let n = Int(readUInt16(data, i)); i += 2
                guard i + n <= end else { return nil }
                sets.append(data.subdata(in: i..<(i + n))); i += n
            }
        }
        let nal = data.subdata(in: (b + headerSize + setsLength)..<data.endIndex)
        return Frame(keyframe: flags & keyframeFlag != 0, hevc: flags & hevcFlag != 0, width: width, height: height,
                     presentationMicros: pts, parameterSets: sets, nalData: nal)
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var be = value.bigEndian
        data.append(Data(bytes: &be, count: 2))
    }

    private static func readUInt16(_ data: Data, _ i: Int) -> UInt16 {
        UInt16(data[i]) << 8 | UInt16(data[i + 1])
    }
}

// MARK: - Video over UDP

/// The picture can also travel as UDP datagrams, host → phone, on the same port as the TCP
/// service. TCP waits for every lost packet, so one lost packet on Wi-Fi freezes the picture
/// until the retransmit lands; over UDP a lost packet costs at most one frame, and usually
/// nothing, because every group of chunks carries a parity chunk that rebuilds one loss.
///
/// Keys come from the TCP session (nothing is negotiated in the clear):
///   videoKey = HKDF-SHA256(sessionKey, info: "couchpad v2 video", 32 bytes)
///   streamID = HKDF-SHA256(sessionKey, info: "couchpad v2 video id", 8 bytes)
/// Datagram layout, all integers big-endian:
///   0..7    stream id            which TCP session this belongs to (in the clear)
///   8..15   sequence             per direction, never reused under a key
///   16..    AES-256-GCM ciphertext ‖ 16-byte tag
///             nonce = direction ‖ 0 0 0 ‖ sequence   (direction 2 host→phone, 3 phone→host)
///             additional authenticated data = bytes 0..15
/// Receivers drop a sequence they have already seen (64-wide window), and the host only
/// accepts datagrams from the address its TCP session came from.
/// Plaintext, by first byte:
///   0x01  hello (phone → host)   the phone's address for the stream; repeated every second
///   0x02  chunk (host → phone)   1: frame sequence (4), 5: frame bytes (4), 9: chunk bytes (2),
///                                11: data chunks N (2), 13: index (2), 15: group size (1), 16..: bytes
///                                index < N is data chunk `index`; index ≥ N is the parity for
///                                group index − N: the XOR of its data chunks, each padded to
///                                the parity's length. With G = ⌈N / group size⌉ groups, data
///                                chunk i belongs to group i mod G, so a run of up to G lost
///                                packets still costs each group only one chunk. The frame is
///                                a ScreenPacket.
///   0x03  ack   (phone → host)   presentation time (8), same meaning as `v a <pts>`
///   0x04  ping  (host → phone)   nothing; sent while the screen is still so the phone knows
///                                the path is alive (it falls back to TCP after two silent seconds)
///   0x05  nack  (phone → host)   frame sequence (4), count (2), then that many data chunk
///                                indices (2 each): send these again (count 0: the whole frame).
///                                The host re-seals them with fresh sequence numbers from a
///                                short history; a frame older than that is simply gone.
/// The phone starts sending hellos when it asks for the picture; the host sends frames over
/// TCP until a hello arrives and over UDP after. `v t` from the phone (no datagram for a
/// while) switches back to TCP. Missing chunks are first asked for again (nack) while the
/// frames behind wait, up to 100 ms; `v l <frames> <chunks>` then reports frames given up on
/// and how many of their chunks never arrived (the host answers with a keyframe, adds parity
/// and lowers the bitrate for a while).
enum VideoDatagram {
    static let videoInfo = Data("couchpad v2 video".utf8)
    static let idInfo = Data("couchpad v2 video id".utf8)
    static let hostDirection: UInt8 = 2
    static let phoneDirection: UInt8 = 3
    static let headerSize = 16
    static let tagSize = 16
    static let chunkHeader = 16
    /// Fits in one Wi-Fi/Ethernet MTU with IPv6 and UDP headers to spare.
    static let maxDatagram = 1200
    static let chunkBytes = maxDatagram - headerSize - tagSize - chunkHeader
    /// Data chunks per parity chunk by default: 20% overhead, one loss per group recovered.
    /// The host shrinks the group while the phone reports losses (more parity, fewer gaps).
    static let groupSize = 5

    enum MessageType: UInt8 { case hello = 1, chunk = 2, ack = 3, ping = 4, nack = 5 }

    static func key(from sessionKey: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, info: videoInfo, outputByteCount: 32)
    }

    static func streamID(from sessionKey: SymmetricKey) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: sessionKey, info: idInfo, outputByteCount: 8).withUnsafeBytes { Data($0) }
    }

    /// The stream id of a datagram, before decrypting it: which session's key to try.
    static func streamID(of datagram: Data) -> Data? {
        datagram.count >= headerSize + tagSize ? datagram.prefix(8) : nil
    }

    static let hello = Data([MessageType.hello.rawValue])
    static let ping = Data([MessageType.ping.rawValue])

    /// Asks for chunks of a frame again: `missing` data chunk indices, or everything if empty.
    static func nack(sequence: UInt32, missing: [Int]) -> Data {
        var out = Data([MessageType.nack.rawValue])
        appendUInt(&out, UInt64(sequence), bytes: 4)
        appendUInt(&out, UInt64(missing.count), bytes: 2)
        for i in missing { appendUInt(&out, UInt64(i), bytes: 2) }
        return out
    }

    static func ack(_ pts: UInt64) -> Data {
        var out = Data([MessageType.ack.rawValue])
        appendUInt(&out, pts, bytes: 8)
        return out
    }

    /// Splits one frame into chunk plaintexts (data chunks, then parity chunks).
    static func chunks(frame: Data, sequence: UInt32, groupSize: Int = groupSize) -> [Data] {
        let groupSize = max(1, min(255, groupSize))
        let count = max(1, (frame.count + chunkBytes - 1) / chunkBytes)
        let groups = (count + groupSize - 1) / groupSize
        var out: [Data] = []
        out.reserveCapacity(count + groups)
        func header(index: Int) -> Data {
            var h = Data([MessageType.chunk.rawValue])
            appendUInt(&h, UInt64(sequence), bytes: 4)
            appendUInt(&h, UInt64(frame.count), bytes: 4)
            appendUInt(&h, UInt64(chunkBytes), bytes: 2)
            appendUInt(&h, UInt64(count), bytes: 2)
            appendUInt(&h, UInt64(index), bytes: 2)
            h.append(UInt8(groupSize))
            return h
        }
        for i in 0..<count {
            let start = frame.startIndex + i * chunkBytes
            out.append(header(index: i) + frame[start..<min(start + chunkBytes, frame.endIndex)])
        }
        for g in 0..<groups {
            let members = stride(from: g, to: count, by: groups)
            var parity = [UInt8](repeating: 0, count: min(chunkBytes, frame.count - g * chunkBytes))
            for i in members {
                let chunk = out[i].dropFirst(chunkHeader)
                for (k, byte) in chunk.enumerated() { parity[k] ^= byte }
            }
            out.append(header(index: count + g) + Data(parity))
        }
        return out
    }

    static func appendUInt(_ data: inout Data, _ value: UInt64, bytes: Int) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
    }

    static func readUInt(_ data: Data, _ offset: Int, bytes: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<bytes { v = (v << 8) | UInt64(data[data.startIndex + offset + i]) }
        return v
    }
}

/// Seals and opens video datagrams for one session. Not thread-safe: use from one queue.
final class DatagramCipher {
    let streamID: Data
    private let key: SymmetricKey
    private let sendDirection: UInt8
    private let recvDirection: UInt8
    private var counter: UInt64 = 0
    /// Replay window: the highest sequence opened and a bitmask of the 64 below it.
    private var highest: UInt64 = 0
    private var seen: UInt64 = 0
    private var opened = false

    init(sessionKey: SymmetricKey, isHost: Bool) {
        key = VideoDatagram.key(from: sessionKey)
        streamID = VideoDatagram.streamID(from: sessionKey)
        sendDirection = isHost ? VideoDatagram.hostDirection : VideoDatagram.phoneDirection
        recvDirection = isHost ? VideoDatagram.phoneDirection : VideoDatagram.hostDirection
    }

    private func nonce(direction: UInt8, sequence: UInt64) -> AES.GCM.Nonce {
        var bytes = Data([direction, 0, 0, 0])
        VideoDatagram.appendUInt(&bytes, sequence, bytes: 8)
        return try! AES.GCM.Nonce(data: bytes)
    }

    func seal(_ plain: Data) -> Data? {
        var header = streamID
        VideoDatagram.appendUInt(&header, counter, bytes: 8)
        guard let box = try? AES.GCM.seal(plain, using: key, nonce: nonce(direction: sendDirection, sequence: counter), authenticating: header) else { return nil }
        counter += 1
        return header + box.ciphertext + box.tag
    }

    /// The plaintext of a datagram for this stream, or nil if it is for another stream, was
    /// tampered with, or has been seen before.
    func open(_ datagram: Data) -> Data? {
        guard datagram.count >= VideoDatagram.headerSize + VideoDatagram.tagSize, datagram.prefix(8) == streamID else { return nil }
        let sequence = VideoDatagram.readUInt(datagram, 8, bytes: 8)
        guard isFresh(sequence) else { return nil }
        let body = datagram.dropFirst(VideoDatagram.headerSize)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce(direction: recvDirection, sequence: sequence),
                                               ciphertext: body.dropLast(VideoDatagram.tagSize), tag: body.suffix(VideoDatagram.tagSize)),
              let plain = try? AES.GCM.open(box, using: key, authenticating: datagram.prefix(VideoDatagram.headerSize)) else { return nil }
        mark(sequence)   // only after the tag checked out, so forgeries can't poison the window
        return plain
    }

    private func isFresh(_ sequence: UInt64) -> Bool {
        guard opened else { return true }
        if sequence > highest { return true }
        let back = highest - sequence
        return back < 64 && seen & (1 << back) == 0
    }

    private func mark(_ sequence: UInt64) {
        if !opened {
            opened = true
            highest = sequence
            seen = 1
        } else if sequence > highest {
            let shift = sequence - highest
            seen = shift >= 64 ? 0 : seen << shift
            seen |= 1
            highest = sequence
        } else {
            seen |= 1 << (highest - sequence)
        }
    }
}

/// Puts frames back together from chunk plaintexts, repairing one lost chunk per group from
/// its parity, asking the host again for what is still missing (a NACK), holding later
/// frames meanwhile so they are delivered in order, and giving up on a frame that stays
/// incomplete too long.
final class FrameAssembler {
    struct Delivery {
        var frames: [Data] = []
        /// Chunks to ask for again: a frame sequence and the data chunk indices missing
        /// (empty = the whole frame, nothing of it arrived).
        var nacks: [(sequence: UInt32, missing: [Int])] = []
    }

    private struct Pending {
        var bytes: Int
        var chunkBytes: Int
        var count: Int
        var group: Int
        var data: [Int: Data] = [:]
        var parity: [Int: Data] = [:]
        var complete: Data?
        var firstAt: Date
        var lastChunkAt: Date
        var lastNackAt: Date?
    }

    private var pending: [UInt32: Pending] = [:]
    private var nextExpected: UInt32?
    private var gapNackAt: Date?
    /// How long a frame may stay incomplete after its first chunk before it counts as lost.
    var timeout: TimeInterval = 0.1
    /// How soon after the last chunk, and how often, to ask again for missing chunks.
    var nackDelay: TimeInterval = 0.015

    /// Frames given up on and the chunks of theirs that never came, since the last `takeLoss`.
    private(set) var lostFrames = 0
    private(set) var lostChunks = 0
    func takeLoss() -> (frames: Int, chunks: Int) {
        defer { lostFrames = 0; lostChunks = 0 }
        return (lostFrames, lostChunks)
    }

    func reset() {
        pending.removeAll()
        nextExpected = nil
        gapNackAt = nil
    }

    /// Feeds one chunk plaintext (first byte 0x02).
    func add(_ chunk: Data) -> Delivery {
        var out = Delivery()
        guard chunk.count >= VideoDatagram.chunkHeader else { return out }
        let sequence = UInt32(VideoDatagram.readUInt(chunk, 1, bytes: 4))
        let bytes = Int(VideoDatagram.readUInt(chunk, 5, bytes: 4))
        let chunkBytes = Int(VideoDatagram.readUInt(chunk, 9, bytes: 2))
        let count = Int(VideoDatagram.readUInt(chunk, 11, bytes: 2))
        let index = Int(VideoDatagram.readUInt(chunk, 13, bytes: 2))
        let group = Int(chunk[chunk.startIndex + 15])
        guard count > 0, chunkBytes > 0, group > 0, bytes <= SecureChannel.maxFrame, index < count + (count + group - 1) / group else { return out }
        if let next = nextExpected, sequence < next { return out }   // a straggler from a frame already shown or given up
        let now = Date()
        var p = pending[sequence] ?? Pending(bytes: bytes, chunkBytes: chunkBytes, count: count, group: group, firstAt: now, lastChunkAt: now)
        p.lastChunkAt = now
        let payload = chunk.dropFirst(VideoDatagram.chunkHeader)
        if index < count { p.data[index] = Data(payload) } else { p.parity[index - count] = Data(payload) }
        if p.complete == nil { p.complete = assemble(p) }
        pending[sequence] = p
        // The host has moved on to this frame: whatever older frames still lack is lost in
        // the air, not merely late. Ask for it now rather than waiting.
        for (older, q) in pending where older < sequence && q.complete == nil { nackIfDue(older, q, now: now, into: &out) }
        if pending.count > 32 { pending = pending.filter { $0.key + 32 > sequence } }
        flush(now: now, into: &out)
        return out
    }

    /// Call every 10 ms or so: asks again for what is still missing and gives up on frames
    /// that have waited too long, so the ones behind them can be shown.
    func tick() -> Delivery {
        var out = Delivery()
        let now = Date()
        for (sequence, p) in pending where p.complete == nil && now.timeIntervalSince(p.lastChunkAt) > nackDelay {
            nackIfDue(sequence, p, now: now, into: &out)
        }
        flush(now: now, into: &out)
        return out
    }

    private func nackIfDue(_ sequence: UInt32, _ p: Pending, now: Date, into out: inout Delivery) {
        if let last = p.lastNackAt, now.timeIntervalSince(last) < nackDelay { return }
        pending[sequence]?.lastNackAt = now
        out.nacks.append((sequence, (0..<p.count).filter { p.data[$0] == nil }))
    }

    /// Delivers complete frames in order; gives up on the ones in front that are out of time.
    private func flush(now: Date, into out: inout Delivery) {
        while true {
            if nextExpected == nil {
                // Starting up: the first complete frame sets the sequence.
                guard let first = pending.filter({ $0.value.complete != nil }).keys.min() else { return }
                pending = pending.filter { $0.key >= first }
                nextExpected = first
            }
            guard let next = nextExpected else { return }
            if let p = pending[next] {
                if let frame = p.complete {
                    out.frames.append(frame)
                    pending[next] = nil
                    nextExpected = next + 1
                    continue
                }
                guard now.timeIntervalSince(p.firstAt) > timeout else { return }
                lostFrames += 1
                lostChunks += p.count - p.data.count
                pending[next] = nil
                nextExpected = next + 1
                continue
            }
            // Nothing of this frame arrived. If later frames are here, ask for it whole, and
            // give it up once the frame after it has waited the full timeout.
            guard let later = pending.keys.filter({ $0 > next }).min(), let q = pending[later] else { return }
            if now.timeIntervalSince(q.firstAt) > timeout {
                lostFrames += Int(later - next)
                nextExpected = later
                gapNackAt = nil
                continue
            }
            if gapNackAt == nil || now.timeIntervalSince(gapNackAt!) >= nackDelay {
                gapNackAt = now
                for missing in next..<later { out.nacks.append((missing, [])) }
            }
            return
        }
    }

    private func assemble(_ p: Pending) -> Data? {
        var slices = (0..<p.count).map { p.data[$0] }
        if slices.contains(where: { $0 == nil }) {
            let groups = (p.count + p.group - 1) / p.group
            for g in 0..<groups {
                let members = stride(from: g, to: p.count, by: groups)
                let missing = members.filter { slices[$0] == nil }
                guard missing.count == 1, let parity = p.parity[g] else { continue }
                var recovered = [UInt8](parity)
                for i in members where i != missing[0] {
                    for (k, byte) in slices[i]!.enumerated() where k < recovered.count { recovered[k] ^= byte }
                }
                let length = missing[0] == p.count - 1 ? p.bytes - missing[0] * p.chunkBytes : p.chunkBytes
                guard length >= 0, length <= recovered.count else { return nil }
                slices[missing[0]] = Data(recovered.prefix(length))
            }
            if slices.contains(where: { $0 == nil }) { return nil }
        }
        var frame = Data(capacity: p.bytes)
        for slice in slices { frame.append(slice!) }
        return frame.count == p.bytes ? frame : nil
    }
}
