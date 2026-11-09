import AVFoundation
import QuartzCore
import os

// The Mac's sound on the phone (AudioPacket in SecureChannel.swift), in three layers:
// AudioJitterBuffer decides what plays when and knows nothing of threads or audio hardware,
// so it can be run against a simulated network on a Mac; AudioRenderer hands it packets and
// picture times across threads and runs it inside the audio render callback; AudioPlayer
// (iOS only) owns the audio session and the engine that callback belongs to.

/// Decodes one stream's packets strictly in order, for AudioJitterBuffer. The frames of the
/// last decode stay readable through `left` and `right` until the next call.
protocol AudioPacketDecoder: AnyObject {
    /// Starts over for a stream of this shape, forgetting earlier packets.
    func reset(channels: Int, framesPerPacket: Int)
    /// Decodes the next packet, or with nil conceals a lost one; the frames it produced, or
    /// 0 if it failed.
    func decode(_ packet: Data?) -> Int
    var left: UnsafePointer<Float> { get }
    /// The same as `left` for a mono stream.
    var right: UnsafePointer<Float> { get }
}

/// Opus through a single AVAudioConverter whose input and output buffers are made once per
/// stream shape and reused for every packet. An empty input packet (no bytes, one packet
/// description of size 0) makes it conceal a lost packet from what it has heard so far. The
/// first packet after a reset yields fewer frames than the rest: the encoder's lookahead
/// (120 frames) comes off the front of the stream.
final class OpusDecoder: AudioPacketDecoder {
    /// Opus packets top out at 1275 bytes; anything bigger is not one of ours.
    static let maxPacketBytes = 1500
    /// Room for the longest Opus packet (120 ms) in the output, whatever the host sends.
    static let maxFrames = 5760

    private var converter: AVAudioConverter?
    private var input: AVAudioCompressedBuffer?
    private var output: AVAudioPCMBuffer?
    private var channels = 0
    private var framesPerPacket = 0
    private var fed = false
    private let silence = UnsafeMutablePointer<Float>.allocate(capacity: OpusDecoder.maxFrames)

    init() {
        silence.initialize(repeating: 0, count: Self.maxFrames)
        // Made here, for the stream the host sends, so the render thread only ever resets it;
        // another shape (never sent today) would be built there.
        reset(channels: 2, framesPerPacket: AudioPacket.framesPerPacket)
    }

    deinit {
        silence.deallocate()
    }

    var left: UnsafePointer<Float> { UnsafePointer(output?.floatChannelData?[0] ?? silence) }
    var right: UnsafePointer<Float> {
        guard let data = output?.floatChannelData else { return UnsafePointer(silence) }
        return UnsafePointer(channels > 1 ? data[1] : data[0])
    }

    func reset(channels: Int, framesPerPacket: Int) {
        if let converter, channels == self.channels, framesPerPacket == self.framesPerPacket {
            converter.reset()
            return
        }
        self.channels = channels
        self.framesPerPacket = framesPerPacket
        let rate = Double(AudioPacket.sampleRate)
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                                      mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
                                                      mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        // Mono decodes to mono and is read twice (`right` is `left`), rather than trusting the
        // converter's channel mapping to fill both sides.
        guard let opus = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false),
              let converter = AVAudioConverter(from: opus, to: pcm),
              let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(Self.maxFrames)) else {
            self.converter = nil
            input = nil
            output = nil
            return
        }
        self.converter = converter
        self.output = output
        input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: Self.maxPacketBytes)
    }

    func decode(_ packet: Data?) -> Int {
        guard let converter, let input, let output else { return 0 }
        let bytes = packet?.count ?? 0
        guard bytes <= Self.maxPacketBytes else { return 0 }
        if let packet, bytes > 0 {
            packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        }
        input.byteLength = UInt32(bytes)
        input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes))
        output.frameLength = 0
        fed = false
        var error: NSError?
        // One packet per call: the converter asks again once it has turned it into samples,
        // and "no data now" (not end of stream) keeps its state for the next packet.
        let status = converter.convert(to: output, error: &error) { [unowned self] _, inputStatus in
            if self.fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            self.fed = true
            inputStatus.pointee = .haveData
            return input
        }
        return status == .error ? 0 : Int(output.frameLength)
    }
}

/// The phone's half of the sound: puts packets back in sequence order, decides how much
/// sound to hold back against the network's jitter, and turns packets into samples when the
/// audio hardware asks for them. Low latency comes first, sound in step with the picture
/// second. Single-threaded and clock-agnostic: every time is passed in, in seconds, on one
/// clock (CACurrentMediaTime on the phone), so it runs as well against a simulated network.
///
/// Packets are keyed by sequence. The first packet sets the playhead; it waits there while
/// buffering (see `margin` below), then playback runs one packet after the other, each
/// decoded in turn:
/// - a packet that is there plays (from a redundant copy: `recovered`);
/// - one that is missing while later ones are queued is concealed by the decoder (`lost`);
/// - with nothing queued at all, the buffer has run dry (`underruns`): the decoder's
///   concealment fades out, the playhead stays put, and buffering starts again. That is
///   also what silence the host didn't send looks like (consecutive sequences, a jump in
///   presentation time), so such a gap is not counted as an underrun, let alone a loss.
///
/// `target` follows the jitter: the 95th percentile of how much later than the quickest one
/// each packet arrived over the last two seconds, plus one packet and 5 ms, between 20 and
/// 150 ms, plus one render callback's length, plus whatever the picture needs (`syncExtra`).
/// It rises at once and falls slowly. It is the queue's depth the moment a packet that came
/// as quickly as any lands. The callback's length is there because a callback decodes ahead:
/// every packet it plays must be in hand when it starts, up to a whole callback before the
/// packet's turn (5 ms at the preferred buffer, 21 ms when iOS hands out 1024 frames).
///
/// What is held to it is not the depth itself, which swings by the whole jitter with every
/// packet, but the `margin`: how long the packet at the playhead will have waited, beyond
/// the quickest transit, when it plays (`now + rest of this packet − its presentation time −
/// min transit`). It is the same for every packet whatever its own delay, changes only when
/// the timeline does, and is the latency itself less the network's floor; it should be the
/// target less one packet. Buffering ends when it gets there. Too high for long, or far too
/// high at once (a burst after a Wi-Fi stall, or the Mac's clock running faster than the
/// phone's), packets are dropped from the front, decoded and thrown away so the decoder's
/// state carries on, with a short crossfade over the cut. Too low for long (a higher target,
/// or the phone's clock running faster), the decoder conceals one packet's worth in between,
/// a hardly audible 10 ms stretch. Neither happens while nothing plays.
final class AudioJitterBuffer {
    static let sampleRate = Double(AudioPacket.sampleRate)
    /// From a picture frame arriving to it being on the glass: the hardware decode plus the
    /// wait for the next display refresh (AVSampleBufferDisplayLayer shows it immediately).
    static let pictureDisplayDelay = 0.010

    struct Tuning {
        var minTarget = 0.020
        var maxTarget = 0.150
        /// Added to the jitter percentile and one packet.
        var margin = 0.005
        /// How fast the target may fall, in seconds per second (1 ms per 100 ms).
        var targetFall = 0.010
        /// The transit window: this long's worth of packets.
        var transitWindow = 2.0
        /// A packet this much later than the quickest is a stall, not jitter: it and the packets
        /// sent while it was held up don't count towards the target. Buffering can't bridge a
        /// stall within the latency budget; the underrun and the trim after it deal with one
        /// (nil: every packet counts, as plain jitter).
        var stallLateness: Double? = 0.100
        /// Packets left out as a stall for longer than this (in presentation time) mean the
        /// delay has gone up for good: the window starts over from them.
        var longestStall = 1.0
        /// Trim when the margin stays this far over its goal for `trimHold`, or at once when it
        /// is `trimJump` over or playback has just resumed; down to less than a packet over
        /// (never under, or a stretch would follow). The margin doesn't swing with the
        /// jitter, so the slack can be tight.
        var trimSlack = 0.010
        var trimHold = 0.3
        var trimJump = 0.100
        /// Stretch when the margin stays this far under its goal for `stretchHold`.
        var stretchSlack = 0.002
        var stretchHold = 0.3
        /// Sync with the picture, once a second: no correction within the dead band, at most
        /// `syncStep` at a time, never more than `maxSyncExtra` of delay.
        var syncDeadband = 0.010
        var syncStep = 0.020
        var maxSyncExtra = 0.150
        /// Fewer picture frames than this in a second is a still screen: nothing to sync with.
        var minPictureFrames = 5
    }

    /// Running totals since the buffer was made (never reset): the report takes differences.
    struct Counters: Equatable {
        var received = 0
        var late = 0
        var lost = 0
        var recovered = 0
        var trimmed = 0
        var underruns = 0
        /// Concealed packets inserted to deepen the queue (not on the wire report).
        var stretched = 0
    }

    struct Status {
        var counters = Counters()
        var depth = 0.0
        var target = 0.0
        var skew = 0.0
    }

    /// A host sequence this far behind the playhead, or this far ahead, is a host that started
    /// over (its counter is per process), not a late or early packet.
    static let restartBehind: Int32 = 50
    static let restartAhead: Int32 = 500
    /// How far a stream may resume from where the buffer ran dry, in presentation time, for
    /// that to count as an underrun rather than silence the host didn't send.
    static let silenceJump = 0.050
    /// Decoded and thrown away at the end of a trim, so the decoder has caught up with the
    /// stream again where playback resumes; packets before them are skipped undecoded, which
    /// keeps a trim of a long gap cheap on the render thread.
    static let trimPrimer = 3
    /// Fade-in after silence, and the crossfade over a trim: 5 ms.
    static let rampFrames = 240

    let tuning: Tuning
    private let decoder: AudioPacketDecoder

    private(set) var counters = Counters()
    private(set) var target: Double
    /// How much later the sound plays than the picture shows, measured once a second.
    private(set) var skew = 0.0
    private(set) var syncExtra = 0.0
    private(set) var playing = false
    /// Presentation time of the first frame of sound in the last render, nil if it had none.
    private(set) var lastRenderedPTS: Double?
    /// The last render had any sound in it (else it was all silence).
    private(set) var lastRenderAudible = false
    /// The margin at the start of the last render (see the type's comment).
    private(set) var lastMargin: Double?

    // The stream
    private var channels = 2
    private var framesPerPacket = AudioPacket.framesPerPacket
    private var duration: Double { Double(framesPerPacket) / Self.sampleRate }

    // The queue: a ring indexed by sequence, wide enough for anything up to `restartAhead`.
    private struct Slot {
        var sequence: UInt32 = 0
        var filled = false
        /// Came as its own datagram's packet, not as a redundant copy in a later one.
        var own = false
        var pts = 0.0
        var data = Data()
    }
    private static let capacity = 512
    private var slots = [Slot](repeating: Slot(), count: capacity)
    /// The next sequence to decode; nil until the first packet.
    private var next: UInt32?
    /// The newest sequence queued (meaningful while not behind `next`).
    private var highest: UInt32 = 0

    // What is being played: the samples of the last decode.
    private enum Kind {
        /// A packet (or a concealed lost one) at its place on the timeline.
        case packet
        /// Concealment inserted to deepen the queue: on no timeline.
        case inserted
        /// Concealment fading out after the buffer ran dry: not queued sound.
        case tail
    }
    private var kind = Kind.packet
    private var pcmLeft: UnsafePointer<Float>
    private var pcmRight: UnsafePointer<Float>
    private var pcmFrames = 0
    private var pcmOffset = 0
    private var pcmStartPTS = 0.0
    /// Frames the decoder's first output after a reset came up short: its output runs this far
    /// behind the packets' presentation times from then on.
    private var decoderLag: Int?
    private var lastDecodedPTS = 0.0
    private let zeros = UnsafeMutablePointer<Float>.allocate(capacity: OpusDecoder.maxFrames)

    // Ramps
    private var fadeIn = 0
    private var crossLeft = [Float](repeating: 0, count: rampFrames)
    private var crossRight = [Float](repeating: 0, count: rampFrames)
    private var crossCount = 0
    private var crossPos = 0

    // Keeping the margin at its goal
    private var overSince: Double?
    private var underSince: Double?
    /// Packets to drop at the next packet boundary.
    private var trimCount = 0
    /// The sequences the last trim skipped (from, up to but not including).
    private var skippedFrom: UInt32 = 0
    private var skippedTo: UInt32 = 0
    /// Playback has just resumed, or a trim couldn't drop all it wanted because the rest of a
    /// burst was still on its way: trim again as soon as it is a packet over, without waiting.
    private var catchingUp = false
    private var stretchPending = false
    /// Where the stream should resume after the buffer ran dry, to tell an underrun from silence.
    private var pendingUnderrunPTS: Double?

    // Transit times (arrival − presentation time) of each datagram's own packet: a ring.
    private static let windowCapacity = 512
    private var transitValue = [Double](repeating: 0, count: windowCapacity)
    private var transitHead = 0
    private var transitCount = 0
    private var histogram = [Int](repeating: 0, count: 301)
    /// The quickest transit in the window: the network's floor, as seen through both clocks.
    private var transitLow: Double?
    private var rawTarget: Double
    private var stallUntilPTS = -Double.infinity
    /// Presentation time of the first packet of the current run left out as a stall.
    private var stallSincePTS: Double?
    private var lastOwnSequence: UInt32?
    private var lastOwnPTS = 0.0
    /// The first sequence of the current presentation-time epoch (since the host's capture
    /// last started over), and the network's floor as the epoch before it saw it: packets
    /// from before the restart may still be queued, or still on their way, and their times
    /// only make sense against that floor.
    private var epochStart: UInt32?
    private var previousLow: Double?

    // The picture: when each frame arrived, as an offset from its presentation time.
    private static let videoCapacity = 256
    private var videoAt = [Double](repeating: 0, count: videoCapacity)
    private var videoOffset = [Double](repeating: 0, count: videoCapacity)
    private var videoHead = 0
    private var videoCount = 0
    private var sortScratch = [Double](repeating: 0, count: videoCapacity)
    private var lastVideoPTS: Double?
    /// When the sound plays, as an offset from its presentation time (same clock as the
    /// picture's, so the unknown offset between the Mac's clock and the phone's cancels).
    private var audioOffset: Double?
    private var audioOffsetAt = 0.0
    private var lastTick: Double?
    private var lastRenderAt: Double?

    init(decoder: AudioPacketDecoder, tuning: Tuning = Tuning()) {
        self.decoder = decoder
        self.tuning = tuning
        target = tuning.minTarget
        rawTarget = tuning.minTarget
        zeros.initialize(repeating: 0, count: OpusDecoder.maxFrames)
        pcmLeft = UnsafePointer(zeros)
        pcmRight = UnsafePointer(zeros)
    }

    deinit {
        zeros.deallocate()
    }

    var status: Status { Status(counters: counters, depth: depth, target: target, skew: skew) }

    /// Sound queued ahead of the speaker: the rest of the packet being played and every
    /// sequence from the playhead to the newest one queued (gaps included: they will play
    /// as concealment).
    var depth: Double {
        queuedDepth + (kind == .tail ? 0 : Double(pcmFrames - pcmOffset) / Self.sampleRate)
    }

    private var queuedCount: Int {
        guard let next else { return 0 }
        return max(0, Int(Int32(bitPattern: highest &- next)) + 1)
    }

    private var queuedDepth: Double { Double(queuedCount) * duration }

    /// Forgets the stream (not the counters): the next packet starts it over.
    func reset() {
        for i in slots.indices { slots[i].filled = false }
        next = nil
        playing = false
        kind = .packet
        pcmFrames = 0
        pcmOffset = 0
        fadeIn = 0
        crossCount = 0
        crossPos = 0
        overSince = nil
        underSince = nil
        trimCount = 0
        catchingUp = false
        stretchPending = false
        pendingUnderrunPTS = nil
        transitHead = 0
        transitCount = 0
        transitLow = nil
        stallUntilPTS = -.infinity
        stallSincePTS = nil
        lastOwnSequence = nil
        epochStart = nil
        previousLow = nil
        skippedFrom = 0
        skippedTo = 0
        rawTarget = tuning.minTarget
        target = tuning.minTarget
        syncExtra = 0
        skew = 0
        videoCount = 0
        lastVideoPTS = nil
        audioOffset = nil
        lastRenderedPTS = nil
    }

    // MARK: Arrivals

    /// One packet as it came off the network (any number of payloads), and when it arrived.
    func insert(_ packet: AudioPacket.Packet, arrival: Double) {
        guard !packet.payloads.isEmpty, packet.framesPerPacket > 0, packet.framesPerPacket <= OpusDecoder.maxFrames else { return }
        let pts = Double(packet.presentationMicros) / 1_000_000
        if let next {
            let ahead = Int32(bitPattern: packet.sequence &- next)
            if ahead < -Self.restartBehind || ahead > Self.restartAhead
                || packet.channels != channels || packet.framesPerPacket != framesPerPacket {
                reset()
            }
        }
        if next == nil { begin(packet, pts: pts) }
        guard let next else { return }
        noteTransit(sequence: packet.sequence, pts: pts, arrival: arrival)
        for (i, payload) in packet.payloads.enumerated() {
            let sequence = packet.sequence &- UInt32(i)
            let ahead = Int32(bitPattern: sequence &- next)
            if ahead < 0 {
                // Its turn has passed. Copies of packets already played are expected; only a
                // datagram's own packet coming after its turn says the buffer was too short
                // (not one a trim skipped: that one's turn never came).
                if i == 0, Int32(bitPattern: sequence &- skippedFrom) < 0 || Int32(bitPattern: sequence &- skippedTo) >= 0 {
                    counters.late += 1
                }
                continue
            }
            guard ahead < Self.capacity else { continue }
            let index = Int(sequence % UInt32(Self.capacity))
            if slots[index].filled, slots[index].sequence == sequence {
                if i == 0 { slots[index].own = true }   // the copy came first; the original made it after all
                continue
            }
            slots[index] = Slot(sequence: sequence, filled: true, own: i == 0, pts: pts - Double(i) * duration, data: payload)
            counters.received += 1
            if Int32(bitPattern: sequence &- highest) > 0 { highest = sequence }
        }
    }

    private func begin(_ packet: AudioPacket.Packet, pts: Double) {
        next = packet.sequence
        highest = packet.sequence &- 1
        channels = packet.channels
        framesPerPacket = packet.framesPerPacket
        decoder.reset(channels: channels, framesPerPacket: framesPerPacket)
        decoderLag = nil
        playing = false
        lastDecodedPTS = pts - duration
    }

    /// Keeps the transit window (own packets only, late ones included: they are the reason
    /// to hold back more) and the target it gives.
    private func noteTransit(sequence: UInt32, pts: Double, arrival: Double) {
        if let last = lastOwnSequence {
            let newer = Int32(bitPattern: sequence &- last) > 0
            if newer, pts < lastOwnPTS {
                // The host's capture started over: presentation times restart while sequences
                // carry on. Transit times from before mean nothing against the new ones.
                epochStart = sequence
                previousLow = transitLow
                transitCount = 0
                transitLow = nil
                stallUntilPTS = -.infinity
                stallSincePTS = nil
            }
            if newer {
                lastOwnSequence = sequence
                lastOwnPTS = pts
            }
        } else {
            lastOwnSequence = sequence
            lastOwnPTS = pts
        }
        if let epochStart, Int32(bitPattern: sequence &- epochStart) < 0 { return }   // a straggler from before
        let transit = arrival - pts
        if let stall = tuning.stallLateness, transitCount > 0 {
            let lateness = transit - minTransit()
            if lateness > stall || pts < stallUntilPTS {
                // Everything sent while this one was held up comes in the same burst. A "stall"
                // that goes on for longer than any does is the network's new normal instead.
                if lateness > stall { stallUntilPTS = max(stallUntilPTS, pts + lateness) }
                let since = stallSincePTS ?? pts
                stallSincePTS = since
                guard pts - since > tuning.longestStall else { return }
                transitCount = 0
                stallUntilPTS = -.infinity
            }
        }
        stallSincePTS = nil
        // The window is the last two seconds' worth of packets rather than of time, so a
        // silence the host didn't send doesn't empty it: the network's floor is the same on
        // the far side, and learning it again would push the latency up after every pause.
        let capacity = min(Self.windowCapacity, max(1, Int((tuning.transitWindow / duration).rounded())))
        while transitCount >= capacity {
            transitHead = (transitHead + 1) % Self.windowCapacity
            transitCount -= 1
        }
        let slot = (transitHead + transitCount) % Self.windowCapacity
        transitValue[slot] = transit
        transitCount += 1
        updateRawTarget()
    }

    private func minTransit() -> Double {
        var low = Double.infinity
        for k in 0..<transitCount { low = min(low, transitValue[(transitHead + k) % Self.windowCapacity]) }
        return low
    }

    private func updateRawTarget() {
        let low = minTransit()
        transitLow = low
        for b in histogram.indices { histogram[b] = 0 }
        for k in 0..<transitCount {
            let ms = Int((transitValue[(transitHead + k) % Self.windowCapacity] - low) * 1000)
            histogram[min(max(ms, 0), histogram.count - 1)] += 1
        }
        let rank = Int((Double(transitCount) * 0.95).rounded(.up))
        var seen = 0
        var p95 = 0.0
        for (b, n) in histogram.enumerated() {
            seen += n
            if seen >= rank {
                p95 = Double(b + 1) / 1000
                break
            }
        }
        rawTarget = min(max(p95 + duration + tuning.margin, tuning.minTarget), tuning.maxTarget)
    }

    /// A picture frame arrived (presentation time on the same clock as the sound's).
    func noteVideoFrame(presentationMicros: UInt64, at time: Double) {
        let pts = Double(presentationMicros) / 1_000_000
        if let last = lastVideoPTS, pts < last - 0.5 { videoCount = 0 }   // the picture's stream restarted
        lastVideoPTS = pts
        if videoCount == Self.videoCapacity {
            videoHead = (videoHead + 1) % Self.videoCapacity
            videoCount -= 1
        }
        let slot = (videoHead + videoCount) % Self.videoCapacity
        videoAt[slot] = time
        videoOffset[slot] = time + Self.pictureDisplayDelay - pts
        videoCount += 1
    }

    // MARK: Playback

    /// Fills `frameCount` frames per channel. `now` is the time of the call; `playout` is when
    /// its first frame will be heard (nil if the hardware didn't say), for the sync with the
    /// picture.
    func render(frameCount: Int, now: Double, playout: Double?, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let elapsed = lastRenderAt.map { max(0, now - $0) } ?? 0
        lastRenderAt = now
        // This callback's packets must all be here now (see `target` in the type's comment).
        let wanted = rawTarget + Double(frameCount) / Self.sampleRate + syncExtra
        target = wanted >= target ? wanted : max(wanted, target - tuning.targetFall * elapsed)
        if let last = lastTick {
            if now - last >= 1 {
                tick(now)
                lastTick = now
            }
        } else {
            lastTick = now
        }
        let margin = self.margin(at: now)
        lastMargin = margin
        if !playing, queuedCount > 0, margin.map({ $0 >= marginGoal }) ?? (queuedDepth >= target) { resume() }
        if playing, let margin { watch(margin, now: now) }

        var written = 0
        var firstPTS: Double?
        var firstAt = 0
        while written < frameCount {
            if pcmOffset < pcmFrames {
                let n = min(frameCount - written, pcmFrames - pcmOffset)
                if kind == .packet, firstPTS == nil {
                    firstPTS = pcmStartPTS + Double(pcmOffset) / Self.sampleRate
                    firstAt = written
                }
                copy(n, to: left + written, right + written)
                written += n
                continue
            }
            guard playing, next != nil else { break }
            // Changes to the timeline happen between packets, never inside one.
            if trimCount > 0 {
                trim(trimCount)
                trimCount = 0
            }
            if stretchPending {
                stretchPending = false
                counters.stretched += 1
                decode(nil, pts: lastDecodedPTS + duration, as: .inserted)
                continue
            }
            playNext()
        }
        lastRenderAudible = written > 0
        if written < frameCount {
            (left + written).update(repeating: 0, count: frameCount - written)
            (right + written).update(repeating: 0, count: frameCount - written)
        }
        lastRenderedPTS = firstPTS
        if let firstPTS, let playout {
            audioOffset = playout + Double(firstAt) / Self.sampleRate - firstPTS
            audioOffsetAt = now
        }
    }

    private func resume() {
        playing = true
        overSince = nil
        underSince = nil
        if let expected = pendingUnderrunPTS {
            if abs(playheadPTS() - expected) <= Self.silenceJump { counters.underruns += 1 }
            pendingUnderrunPTS = nil
        }
        fadeIn = Self.rampFrames
        crossCount = 0
        // Coming out of silence, a cut costs nothing: whatever is staler than the goal (the
        // rest of a burst that ended the gap) is skipped before the first packet plays.
        catchingUp = true
    }

    /// What the margin should be: the target is the depth right after a quick packet lands,
    /// which is that packet itself plus the margin.
    private var marginGoal: Double { target - duration }

    /// See the type's comment: how long, beyond the quickest transit, the packet at the
    /// playhead will have waited when it plays. Nil before any transit is known.
    private func margin(at now: Double) -> Double? {
        guard let next, var low = transitLow else { return nil }
        if let epochStart, Int32(bitPattern: next &- epochStart) < 0, let previousLow { low = previousLow }
        let rest = kind == .tail ? 0 : Double(pcmFrames - pcmOffset) / Self.sampleRate
        return now + rest - playheadPTS() - low
    }

    /// The presentation time of the packet at the playhead: its own, or worked out from the
    /// first one queued after it (it may be the one that is late or lost), or from the last
    /// one played.
    private func playheadPTS() -> Double {
        guard let next else { return lastDecodedPTS + duration }
        for j in 0..<min(queuedCount, 64) {
            let sequence = next &+ UInt32(j)
            let index = Int(sequence % UInt32(Self.capacity))
            if slots[index].filled, slots[index].sequence == sequence {
                return slots[index].pts - Double(j) * duration
            }
        }
        return lastDecodedPTS + duration
    }

    private func watch(_ margin: Double, now: Double) {
        let goal = marginGoal
        let over = margin - goal
        // Down to less than a packet over the goal (trim keeps the newest packet, whatever).
        let drop = Int((over / duration).rounded(.down))
        if catchingUp, over < duration { catchingUp = false }
        if over > tuning.trimJump || catchingUp {
            trimCount = max(0, drop)
            overSince = nil
        } else if over > tuning.trimSlack {
            if let since = overSince {
                if now - since >= tuning.trimHold {
                    trimCount = max(0, drop)
                    overSince = nil
                }
            } else {
                overSince = now
            }
        } else {
            overSince = nil
        }
        if over < -tuning.stretchSlack {
            if let since = underSince {
                if now - since >= tuning.stretchHold {
                    stretchPending = true
                    underSince = nil
                }
            } else {
                underSince = now
            }
        } else {
            underSince = nil
        }
    }

    private func playNext() {
        guard let sequence = next else { return }
        let index = Int(sequence % UInt32(Self.capacity))
        if slots[index].filled, slots[index].sequence == sequence {
            slots[index].filled = false
            if !slots[index].own { counters.recovered += 1 }
            decode(slots[index].data, pts: slots[index].pts, as: .packet)
            next = sequence &+ 1
        } else if queuedCount > 0 {
            counters.lost += 1
            decode(nil, pts: playheadPTS(), as: .packet)
            next = sequence &+ 1
        } else {
            // Ran dry. Let the decoder's guess at what came next fade out rather than cut the
            // sound off mid-wave; the playhead waits here for the packet that didn't come.
            playing = false
            pendingUnderrunPTS = lastDecodedPTS + duration
            decode(nil, pts: 0, as: .tail)
        }
    }

    /// Drops `count` packets from the front (fewer if fewer are queued, always keeping one). The
    /// first one dropped is the sound that would have come next, so its start is kept to
    /// crossfade the cut with.
    private func trim(_ count: Int) {
        guard let start = next else { return }
        let drop = min(count, queuedCount - 1)
        if drop < count { catchingUp = true }
        guard drop > 0 else { return }
        let crossfade = fadeIn == 0 && kind != .tail && pcmFrames > 0
        for j in 0..<drop {
            let sequence = start &+ UInt32(j)
            let index = Int(sequence % UInt32(Self.capacity))
            let present = slots[index].filled && slots[index].sequence == sequence
            // Missing or not, the packet's turn is skipped: a trimmed one, not a lost one.
            counters.trimmed += 1
            if present {
                slots[index].filled = false
                lastDecodedPTS = slots[index].pts
            } else {
                lastDecodedPTS += duration
            }
            if j == 0, crossfade {
                let frames = decodeFrames(present ? slots[index].data : nil)
                crossCount = min(Self.rampFrames, frames)
                crossPos = 0
                for i in 0..<crossCount {
                    crossLeft[i] = pcmLeft[i]
                    crossRight[i] = pcmRight[i]
                }
            } else if j >= drop - Self.trimPrimer {
                _ = decodeFrames(present ? slots[index].data : nil)
            }
        }
        next = start &+ UInt32(drop)
        skippedFrom = start
        skippedTo = start &+ UInt32(drop)
        // What was being played is gone from the decoder's buffer now; nothing is left of it.
        pcmFrames = 0
        pcmOffset = 0
    }

    /// Runs the decoder once and points `pcmLeft`/`pcmRight` at what came out (silence if it
    /// failed, so the timeline still moves on by a packet).
    private func decodeFrames(_ data: Data?) -> Int {
        var frames = decoder.decode(data)
        if frames > 0, frames <= OpusDecoder.maxFrames {
            pcmLeft = decoder.left
            pcmRight = decoder.right
        } else {
            frames = framesPerPacket
            pcmLeft = UnsafePointer(zeros)
            pcmRight = UnsafePointer(zeros)
        }
        if decoderLag == nil { decoderLag = max(0, framesPerPacket - frames) }
        return frames
    }

    private func decode(_ data: Data?, pts: Double, as kind: Kind) {
        let frames = decodeFrames(data)
        pcmFrames = frames
        pcmOffset = 0
        self.kind = kind
        // The decoder's output trails the packets by its lag: a full packet's samples start
        // that much before the packet's own presentation time.
        pcmStartPTS = pts + Double(framesPerPacket - (decoderLag ?? 0) - frames) / Self.sampleRate
        if kind == .packet { lastDecodedPTS = pts }
    }

    private func copy(_ n: Int, to left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) {
        let sourceLeft = pcmLeft + pcmOffset
        let sourceRight = pcmRight + pcmOffset
        if fadeIn == 0, crossPos >= crossCount, kind != .tail {
            left.update(from: sourceLeft, count: n)
            right.update(from: sourceRight, count: n)
        } else {
            for i in 0..<n {
                var l = sourceLeft[i]
                var r = sourceRight[i]
                if kind == .tail {
                    let gain = Float(pcmFrames - pcmOffset - i - 1) / Float(pcmFrames)
                    l *= gain
                    r *= gain
                } else {
                    if crossPos < crossCount {
                        let w = Float(crossPos + 1) / Float(crossCount + 1)
                        l = l * w + crossLeft[crossPos] * (1 - w)
                        r = r * w + crossRight[crossPos] * (1 - w)
                        crossPos += 1
                    }
                    if fadeIn > 0 {
                        let gain = Float(Self.rampFrames - fadeIn + 1) / Float(Self.rampFrames)
                        l *= gain
                        r *= gain
                        fadeIn -= 1
                    }
                }
                left[i] = l
                right[i] = r
            }
        }
        pcmOffset += n
    }

    /// Once a second: how far the sound is from the picture, and the delay that corrects it.
    /// Sound is never let run ahead of the picture, and never held back more than the jitter
    /// needs once the picture is in step or gone.
    private func tick(_ now: Double) {
        var n = 0
        for k in 0..<videoCount {
            let i = (videoHead + k) % Self.videoCapacity
            if videoAt[i] >= now - 1 {
                sortScratch[n] = videoOffset[i]
                n += 1
            }
        }
        guard n >= max(1, tuning.minPictureFrames), let audio = audioOffset, now - audioOffsetAt < 1 else {
            skew = 0
            syncExtra = max(0, syncExtra - tuning.syncStep)
            return
        }
        // Insertion sort: a second of frames, in a buffer made once.
        for i in 1..<n {
            let value = sortScratch[i]
            var j = i - 1
            while j >= 0, sortScratch[j] > value {
                sortScratch[j + 1] = sortScratch[j]
                j -= 1
            }
            sortScratch[j + 1] = value
        }
        let median = n % 2 == 1 ? sortScratch[n / 2] : (sortScratch[n / 2 - 1] + sortScratch[n / 2]) / 2
        skew = audio - median
        // Across a restart of the host's capture the two can briefly be on different epochs:
        // a second's disagreement is that, not a skew.
        guard abs(skew) < 1 else {
            skew = 0
            return
        }
        if skew < -tuning.syncDeadband {
            syncExtra = min(tuning.maxSyncExtra, syncExtra + min(-skew, tuning.syncStep))
        } else if skew > tuning.syncDeadband, syncExtra > 0 {
            syncExtra = max(0, syncExtra - min(skew, tuning.syncStep))
        }
    }
}

/// os_unfair_lock at an address of its own: a Swift property's address isn't stable enough
/// for a lock.
final class UnfairLock {
    private let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    init() {
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    func lock() { os_unfair_lock_lock(pointer) }
    func unlock() { os_unfair_lock_unlock(pointer) }
}

/// Runs an AudioJitterBuffer inside the audio render callback. The buffer belongs to the
/// render thread alone; the network queue and the main thread only drop packets and picture
/// times into a mailbox, and read back what the last render published, each under a lock
/// held for a few assignments (the render swaps whole arrays in and out, so it never waits
/// on anyone's work, and nobody waits on a decode).
final class AudioRenderer {
    private let lock = UnfairLock()
    // Under `lock`:
    private var accepting = false
    private var inbox: [(packet: AudioPacket.Packet, arrival: Double)] = []
    private var pictureInbox: [(pts: UInt64, at: Double)] = []
    private var resetPending = true
    private var outputLatency = 0.0
    private var outputMs = 0
    private var published = AudioJitterBuffer.Status()
    private var reported = AudioJitterBuffer.Counters()
    private var echo: (sequence: UInt32, arrival: Double)?
    // Render thread only:
    private let core: AudioJitterBuffer
    private var drained: [(packet: AudioPacket.Packet, arrival: Double)] = []
    private var drainedPictures: [(pts: UInt64, at: Double)] = []
    private let hostTicksToSeconds: Double

    private static let inboxLimit = 256

    init(decoder: AudioPacketDecoder = OpusDecoder()) {
        core = AudioJitterBuffer(decoder: decoder)
        inbox.reserveCapacity(Self.inboxLimit)
        drained.reserveCapacity(Self.inboxLimit)
        pictureInbox.reserveCapacity(Self.inboxLimit)
        drainedPictures.reserveCapacity(Self.inboxLimit)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        hostTicksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// While the engine runs. Turning it on starts the stream over.
    func setAccepting(_ on: Bool) {
        lock.lock()
        accepting = on
        resetPending = true
        inbox.removeAll(keepingCapacity: true)
        pictureInbox.removeAll(keepingCapacity: true)
        echo = nil
        lock.unlock()
    }

    /// Forgets the stream (a new connection: another host, or the same one started over).
    func reset() {
        lock.lock()
        resetPending = true
        inbox.removeAll(keepingCapacity: true)
        pictureInbox.removeAll(keepingCapacity: true)
        echo = nil
        lock.unlock()
    }

    /// The hardware's delay, from the audio session (never read in the render callback).
    func setOutput(latency: Double, ioBuffer: Double) {
        lock.lock()
        outputLatency = latency
        outputMs = Int(((latency + ioBuffer) * 1000).rounded())
        lock.unlock()
    }

    /// Any thread; dropped while the engine isn't running.
    func receive(_ packet: AudioPacket.Packet, arrival: Double) {
        lock.lock()
        if accepting {
            if inbox.count < Self.inboxLimit { inbox.append((packet, arrival)) }
            if echo == nil || Int32(bitPattern: packet.sequence &- echo!.sequence) > 0 { echo = (packet.sequence, arrival) }
        }
        lock.unlock()
    }

    func noteVideoFrame(presentationMicros: UInt64, at time: Double) {
        lock.lock()
        if accepting, pictureInbox.count < Self.inboxLimit { pictureInbox.append((presentationMicros, time)) }
        lock.unlock()
    }

    /// The report for the last second; nil while not playing.
    func takeReport(now: Double) -> AudioPacket.Report? {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return nil }
        let status = published
        let total = status.counters
        let before = reported
        reported = total
        var report = AudioPacket.Report()
        report.received = max(0, total.received - before.received)
        report.late = max(0, total.late - before.late)
        report.lost = max(0, total.lost - before.lost)
        report.recovered = max(0, total.recovered - before.recovered)
        report.trimmed = max(0, total.trimmed - before.trimmed)
        report.underruns = max(0, total.underruns - before.underruns)
        report.bufferMs = Int((status.depth * 1000).rounded())
        report.targetMs = Int((status.target * 1000).rounded())
        report.outputMs = outputMs
        report.skewMs = Int((status.skew * 1000).rounded())
        if let echo {
            report.echoSequence = echo.sequence
            report.echoHeldMicros = max(0, Int(((now - echo.arrival) * 1_000_000).rounded()))
        }
        return report
    }

    /// The render callback's body (an AVAudioSourceNode's, two non-interleaved channels).
    func render(isSilence: UnsafeMutablePointer<ObjCBool>, timestamp: UnsafePointer<AudioTimeStamp>,
                frameCount: AVAudioFrameCount, buffers: UnsafeMutablePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        guard let left = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        let right = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) ?? left : left
        let now = CACurrentMediaTime()
        lock.lock()
        swap(&inbox, &drained)
        swap(&pictureInbox, &drainedPictures)
        let reset = resetPending
        resetPending = false
        let latency = outputLatency
        lock.unlock()

        if reset { core.reset() }
        for item in drained { core.insert(item.packet, arrival: item.arrival) }
        drained.removeAll(keepingCapacity: true)
        for item in drainedPictures { core.noteVideoFrame(presentationMicros: item.pts, at: item.at) }
        drainedPictures.removeAll(keepingCapacity: true)
        let stamp = timestamp.pointee
        // The host time of an output render is when its first frame leaves for the hardware;
        // the session's output latency is the rest of the way to the speaker.
        let playout: Double? = stamp.mFlags.contains(.hostTimeValid) ? Double(stamp.mHostTime) * hostTicksToSeconds + latency : nil
        core.render(frameCount: Int(frameCount), now: now, playout: playout, left: left, right: right)
        isSilence.pointee = ObjCBool(!core.lastRenderAudible)
        let status = core.status

        lock.lock()
        published = status
        lock.unlock()
    }
}

#if os(iOS)
/// Plays the Mac's sound with the picture, on the iPhone's own output. The Client owns one;
/// every entry point is safe from any thread. The audio session and engine are handled on a
/// queue of its own (activating a session can block for a while), and the render callback
/// pulls samples from an AudioRenderer.
///
/// The session plays (`.playback`) because the user turned the sound on in Couchpad: silent
/// mode doesn't mute it, and it mixes with others, so it never stops the user's own music.
final class AudioPlayer {
    private let renderer = AudioRenderer()
    private let queue = DispatchQueue(label: "couchpad.audio")
    // On `queue`:
    private var engine: AVAudioEngine?
    private var wanted = false
    private var running = false
    private var interrupted = false
    private var sessionActive = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let began = type == .began
                self?.queue.async { self?.interruption(began: began) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.routeChanged() }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
                let source = (note.object as AnyObject?).map(ObjectIdentifier.init)
                self?.queue.async { self?.configurationChanged(source) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.mediaServicesReset() }
            },
        ]
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        queue.async {
            self.wanted = true
            self.startEngine()
        }
    }

    func stop() {
        queue.async {
            self.wanted = false
            self.stopEngine()
            self.deactivate()
        }
    }

    /// A new connection: whatever is queued belongs to the old one.
    func reset() { renderer.reset() }

    /// A packet straight off the network (UDP on VideoLink's queue, TCP on the main actor).
    func receive(_ packet: AudioPacket.Packet, arrival: Double = CACurrentMediaTime()) {
        renderer.receive(packet, arrival: arrival)
    }

    /// Every picture frame as it arrives, to keep the sound in step with it.
    func noteVideoFrame(presentationMicros: UInt64) {
        renderer.noteVideoFrame(presentationMicros: presentationMicros, at: CACurrentMediaTime())
    }

    /// What the host's stats line shows for this phone; nil while not playing.
    func takeReport() -> AudioPacket.Report? {
        renderer.takeReport(now: CACurrentMediaTime())
    }

    // MARK: Session and engine (on `queue`)

    private func startEngine() {
        guard wanted, !interrupted, !running else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            // Preferences only: the hardware may settle on something else.
            try? session.setPreferredSampleRate(Double(AudioPacket.sampleRate))
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            sessionActive = true
        } catch {
            NSLog("Sound: the audio session refused: %@", error.localizedDescription)
            return
        }
        refreshLatency()
        let engine = self.engine ?? makeEngine()
        do {
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("Sound: the audio engine didn't start: %@", error.localizedDescription)
            return
        }
        running = true
        renderer.setAccepting(true)
    }

    private func stopEngine() {
        renderer.setAccepting(false)
        if running {
            engine?.stop()
            running = false
        }
    }

    /// Lets other apps' audio know it can take the stage again (it kept playing anyway).
    private func deactivate() {
        guard sessionActive else { return }
        sessionActive = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("Sound: couldn't release the audio session: %@", error.localizedDescription)
        }
    }

    private func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioPacket.sampleRate), channels: 2, interleaved: false)!
        let renderer = self.renderer
        // Pulled by the hardware: each callback decodes just what it plays, so no sound waits
        // in a queue of buffers between the network and the speaker.
        let source = AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, buffers in
            renderer.render(isSilence: isSilence, timestamp: timestamp, frameCount: frameCount, buffers: buffers)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        self.engine = engine
        return engine
    }

    private func refreshLatency() {
        let session = AVAudioSession.sharedInstance()
        renderer.setOutput(latency: session.outputLatency, ioBuffer: session.ioBufferDuration)
    }

    /// A call, Siri, an alarm: the system has stopped us. Play again when it is over, if the
    /// sound is still wanted.
    private func interruption(began: Bool) {
        if began {
            interrupted = true
            stopEngine()
            sessionActive = false
        } else {
            interrupted = false
            startEngine()
        }
    }

    /// Headphones, AirPlay, Bluetooth: the delay to the ear changes with the route.
    private func routeChanged() {
        refreshLatency()
        if running, engine?.isRunning == false {
            running = false
            startEngine()
        }
    }

    /// The hardware's format changed under the engine, which stops it.
    private func configurationChanged(_ source: ObjectIdentifier?) {
        guard let engine, source == ObjectIdentifier(engine) else { return }
        renderer.setAccepting(false)
        running = false
        refreshLatency()
        startEngine()
    }

    /// The media server restarted: every audio object is dead, start from nothing.
    private func mediaServicesReset() {
        renderer.setAccepting(false)
        engine = nil
        running = false
        sessionActive = false
        startEngine()
    }
}
#endif
