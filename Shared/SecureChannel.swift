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
