import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Turns ScreenCaptureKit's audio into Opus packets for the phone: 48 kHz stereo, 480 frames
/// (10 ms) a packet, 128 kbps, through AVAudioConverter. Not thread-safe: use from one queue.
///
/// ScreenCaptureKit hands over buffers of its own size (1024 frames, about 21 ms), so samples
/// wait in a FIFO until a packet's worth is there. Each packet carries its first sample's time
/// on the picture's clock (`presentationMicros`), so the phone can line sound up with frames.
///
/// The timeline is kept in whole microseconds and advances exactly 10 ms a packet, re-anchored
/// to ScreenCaptureKit's timestamps only when the two drift more than a millisecond apart: the
/// phone sees evenly spaced packets, and the sound still can't wander off the picture over an
/// hour. Gaps (ScreenCaptureKit sending nothing for a while, which it may do during silence)
/// end the partial packet with zeros and start the timeline over where the sound resumes;
/// sequence numbers carry on regardless, so to the phone it reads as silence, not loss.
final class AudioEncoder {
    /// Packets out, each with one payload and the host time (CACurrentMediaTime base) of its
    /// first sample, for measuring how old it is when it leaves.
    var onPacket: ((AudioPacket.Packet, Double) -> Void)?

    static let sampleRate = Double(AudioPacket.sampleRate)
    static let framesPerPacket = AudioPacket.framesPerPacket
    static let packetMicros = Int64(framesPerPacket) * 1_000_000 / Int64(AudioPacket.sampleRate)
    /// How far a buffer may start from where the last one ended before it counts as a gap
    /// (or, earlier, as the stream starting over). Timestamps jitter by a few samples.
    static let tolerance = 0.002
    /// A partial packet older than this when a gap closes it is thrown away instead of sent:
    /// the phone would only count it as late. That happens when ScreenCaptureKit stops
    /// delivering during silence and the tail of the last sound waits for the next one.
    static let staleAge = 0.1

    /// One counter for the whole process, +1 a packet: never reset, not even when the stream
    /// restarts. ScreenStreamer owns the only encoder, for as long as the app runs.
    private(set) var nextSequence: UInt32 = 0

    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let opus: AVAudioConverter
    private let packetInput: AVAudioPCMBuffer
    private let packetOutput: AVAudioCompressedBuffer

    /// The FIFO, one plane per channel, and how many frames it holds.
    private let capacity = 8192
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var count = 0
    /// Host time, in µs, of the FIFO's first frame; nil while there is no timeline (before
    /// the first buffer, after a reset or a gap).
    private var headMicros: Int64?
    /// Where the last packet sent ended, so a timeline started again after a gap never
    /// overlaps it (a gap shorter than a packet would, once the partial one is padded).
    private var emittedEndMicros: Int64?
    /// Frames still to throw away from the incoming sound, for that overlap.
    private var skipFrames = 0
    /// Where the next buffer should start, on ScreenCaptureKit's own timestamps.
    private var nextInputTime: Double?
    /// What the current packet's time base is: the stream's start, as host time.
    private var startedAtHostMicros: Int64 = 0

    /// Room for ScreenCaptureKit's AudioBufferList, grown if a buffer needs more. CoreMedia
    /// insists on being told the exact size it asked for (a larger one fails with -12737).
    private var bufferList: UnsafeMutableRawPointer
    private var bufferListSize: Int
    /// Only for buffers that aren't 48 kHz Float32 already (ScreenCaptureKit's usual).
    private var converter: AVAudioConverter?
    private var converterSource: AudioStreamBasicDescription?
    private var converted: AVAudioPCMBuffer?

    init?() {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 2, interleaved: false) else { return nil }
        var desc = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: UInt32(Self.framesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 2,
                                               mBitsPerChannel: 0, mReserved: 0)
        guard let opusFormat = AVAudioFormat(streamDescription: &desc), let opus = AVAudioConverter(from: pcm, to: opusFormat),
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(Self.framesPerPacket)) else { return nil }
        opus.bitRate = 128_000
        pcmFormat = pcm
        self.opusFormat = opusFormat
        self.opus = opus
        packetInput = input
        packetOutput = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: max(opus.maximumOutputPacketSize, 1500))
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        bufferListSize = AudioBufferList.sizeInBytes(maximumBuffers: 8)
        bufferList = .allocate(byteCount: bufferListSize, alignment: 16)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        bufferList.deallocate()
    }

    /// Forgets the FIFO and the timeline: the stream stopped, started again, or sound was
    /// switched back on. The sequence carries on.
    func reset() {
        count = 0
        headMicros = nil
        emittedEndMicros = nil
        nextInputTime = nil
        skipFrames = 0
    }

    /// Feeds one ScreenCaptureKit audio buffer. `startedAtHost` is the picture clock's zero,
    /// as host time: a packet's presentation time is its first sample's host time minus that.
    func append(_ sample: CMSampleBuffer, startedAtHost: Double) {
        startedAtHostMicros = Int64((startedAtHost * 1_000_000).rounded())
        let frames = CMSampleBufferGetNumSamples(sample)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard frames > 0, pts.isValid, let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, asbd.mSampleRate > 0 else { return }

        var needed = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
                                                                      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                                                                      blockBufferOut: nil) == noErr else { return }
        if needed > bufferListSize {
            bufferList.deallocate()
            bufferListSize = needed
            bufferList = .allocate(byteCount: needed, alignment: 16)
        }
        let list = bufferList.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
                                                                      blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                                      blockBufferOut: &block) == noErr else { return }
        withExtendedLifetime(block) {
            let time = pts.seconds
            startTimeline(at: time)
            nextInputTime = time + Double(frames) / asbd.mSampleRate
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            if Self.isNativeFloat(asbd) {
                appendFloat(buffers, asbd: asbd, frames: frames, time: time)
            } else {
                appendConverted(list, asbd: asbd, time: time)
            }
        }
    }

    /// Feeds planar 48 kHz Float32 straight from memory (`right` nil for mono): the harness's
    /// way in, and what both paths above come down to.
    func append(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>?, frames: Int, time: Double, startedAtHost: Double) {
        startedAtHostMicros = Int64((startedAtHost * 1_000_000).rounded())
        startTimeline(at: time)
        nextInputTime = time + Double(frames) / Self.sampleRate
        anchor(at: time)
        push(frames: frames) { start, n in
            (self.left + self.count).update(from: l + start, count: n)
            (self.right + self.count).update(from: (r ?? l) + start, count: n)
        }
    }

    // MARK: Timeline

    /// Decides where a buffer starting at `time` goes: right after the FIFO (the usual case),
    /// after a gap, or at the start of a new stream.
    private func startTimeline(at time: Double) {
        if let expected = nextInputTime {
            if time > expected + Self.tolerance {
                flushPartial()
            } else if time < expected - Self.tolerance {
                // Earlier than the last buffer ended: the stream started over.
                reset()
            }
        }
    }

    /// Pads the partial packet with silence and sends it (unless it has gone stale), then
    /// drops the timeline so the next samples start a new one.
    private func flushPartial() {
        if count > 0, let head = headMicros {
            if CACurrentMediaTime() - Double(head) / 1_000_000 < Self.staleAge {
                (left + count).update(repeating: 0, count: Self.framesPerPacket - count)
                (right + count).update(repeating: 0, count: Self.framesPerPacket - count)
                count = Self.framesPerPacket
                drain()
            } else {
                emittedEndMicros = head
            }
        }
        count = 0
        headMicros = nil
    }

    /// Ties the FIFO's head to the timestamp of the buffer about to be appended: starts the
    /// timeline if there is none, and nudges it if it has drifted off by more than 1 ms.
    private func anchor(at time: Double) {
        let anchored = Int64((time * 1_000_000).rounded()) - Int64(count) * 1_000_000 / Int64(AudioPacket.sampleRate)
        guard let head = headMicros else {
            // After a gap shorter than a packet, the padded packet already covers the start of
            // what came next: skip what overlaps rather than send two sounds for one moment.
            if let end = emittedEndMicros, anchored < end, count == 0 {
                skipFrames = Int(((end - anchored) * Int64(AudioPacket.sampleRate) + 500_000) / 1_000_000)
                headMicros = end
            } else {
                headMicros = anchored
            }
            return
        }
        if abs(anchored - head) > 1000 { headMicros = anchored }
    }

    /// Appends frames in pieces that fit the FIFO, sending packets as they fill. `copy` writes
    /// `n` frames, from `start` in the source, at the FIFO's end.
    private func push(frames: Int, copy: (_ start: Int, _ n: Int) -> Void) {
        var done = min(frames, skipFrames)
        skipFrames -= done
        while done < frames {
            let n = min(frames - done, capacity - count)
            copy(done, n)
            count += n
            done += n
            drain()
        }
    }

    // MARK: Input formats

    private static func isNativeFloat(_ asbd: AudioStreamBasicDescription) -> Bool {
        asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 && asbd.mBitsPerChannel == 32
            && asbd.mSampleRate == sampleRate && asbd.mChannelsPerFrame >= 1
    }

    /// 48 kHz Float32, planar (one buffer per channel, ScreenCaptureKit's usual) or
    /// interleaved, mono or stereo (beyond two channels, the first two).
    private func appendFloat(_ buffers: UnsafeMutableAudioBufferListPointer, asbd: AudioStreamBasicDescription, frames: Int, time: Double) {
        anchor(at: time)
        let channels = Int(asbd.mChannelsPerFrame)
        if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            guard let l = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
            let r = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? l : l
            let available = buffers.map { Int($0.mDataByteSize) / 4 }.min() ?? 0
            push(frames: min(frames, available)) { start, n in
                (self.left + self.count).update(from: l + start, count: n)
                (self.right + self.count).update(from: r + start, count: n)
            }
        } else {
            guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self), let first = buffers.first else { return }
            let stride = max(1, Int(first.mNumberChannels))
            let available = Int(first.mDataByteSize) / 4 / stride
            let second = min(1, min(channels, stride) - 1)
            push(frames: min(frames, available)) { start, n in
                for i in 0..<n {
                    self.left[self.count + i] = data[(start + i) * stride]
                    self.right[self.count + i] = data[(start + i) * stride + second]
                }
            }
        }
    }

    /// Anything else (another rate, integer samples) goes through an AVAudioConverter to
    /// 48 kHz Float32 first. Its own small delay shows up as a fixed offset well under the
    /// 1 ms the timeline tolerates.
    private func appendConverted(_ list: UnsafeMutablePointer<AudioBufferList>, asbd: AudioStreamBasicDescription, time: Double) {
        var source = asbd
        if converter == nil || !Self.same(converterSource, asbd) {
            converter = nil
            converted = nil
            converterSource = asbd
            let channels = AVAudioChannelCount(min(2, max(1, asbd.mChannelsPerFrame)))
            guard let from = AVAudioFormat(streamDescription: &source),
                  let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: channels, interleaved: false),
                  let made = AVAudioConverter(from: from, to: to) else {
                NSLog("Sound: can't convert %.0f Hz, format %u, flags %u, %u channels", asbd.mSampleRate, asbd.mFormatID, asbd.mFormatFlags, asbd.mChannelsPerFrame)
                return
            }
            converter = made
        }
        guard let converter, let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, bufferListNoCopy: list, deallocator: nil) else { return }
        let needed = AVAudioFrameCount(Double(input.frameLength) * Self.sampleRate / asbd.mSampleRate) + 1024
        if converted == nil || converted!.frameCapacity < needed {
            converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: needed)
        }
        guard let output = converted else { return }
        output.frameLength = 0
        var given = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0, let planes = output.floatChannelData else { return }
        anchor(at: time)
        let l = UnsafePointer(planes[0])
        let r = output.format.channelCount > 1 ? UnsafePointer(planes[1]) : l
        push(frames: Int(output.frameLength)) { start, n in
            (self.left + self.count).update(from: l + start, count: n)
            (self.right + self.count).update(from: r + start, count: n)
        }
    }

    private static func same(_ a: AudioStreamBasicDescription?, _ b: AudioStreamBasicDescription) -> Bool {
        guard let a else { return false }
        return a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBitsPerChannel == b.mBitsPerChannel && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBytesPerFrame == b.mBytesPerFrame
    }

    // MARK: Opus

    /// Encodes every whole packet in the FIFO and moves what is left to the front.
    private func drain() {
        let packet = Self.framesPerPacket
        var offset = 0
        while count - offset >= packet {
            if let head = headMicros {
                encode(from: offset, head: head)
                headMicros = head + Self.packetMicros
            }
            offset += packet
        }
        guard offset > 0 else { return }
        count -= offset
        if count > 0 {
            left.update(from: left + offset, count: count)
            right.update(from: right + offset, count: count)
        }
    }

    private func encode(from offset: Int, head: Int64) {
        guard let planes = packetInput.floatChannelData else { return }
        let n = Self.framesPerPacket
        planes[0].update(from: left + offset, count: n)
        planes[1].update(from: right + offset, count: n)
        packetInput.frameLength = AVAudioFrameCount(n)
        packetOutput.byteLength = 0
        packetOutput.packetCount = 0
        var given = false
        var error: NSError?
        let status = opus.convert(to: packetOutput, error: &error) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true
            state.pointee = .haveData
            return self.packetInput
        }
        guard status != .error, packetOutput.packetCount > 0, packetOutput.byteLength > 0 else {
            if let error { NSLog("Sound: Opus encode failed: %@", error.localizedDescription) }
            return
        }
        let payload = Data(bytes: packetOutput.data, count: Int(packetOutput.byteLength))
        let packet = AudioPacket.Packet(channels: 2, sequence: nextSequence, presentationMicros: UInt64(max(0, head - startedAtHostMicros)), payloads: [payload])
        nextSequence &+= 1
        emittedEndMicros = head + Self.packetMicros
        onPacket?(packet, Double(head) / 1_000_000)
    }
}

/// Which earlier packets ride along with the newest one in a UDP datagram, as insurance
/// against loss: up to two, newest first, each only if it directly precedes the one after it
/// in both sequence and time (a packet from before a gap or a restart would be placed wrong),
/// and only while the datagram stays within AudioPacket.maxDatagramPlaintext. The newest goes
/// out even if it alone is too big: a lost redundant copy costs nothing, a missing packet does.
enum AudioRedundancy {
    static let maxCopies = 2

    /// `previous` is newest first; returns the payloads for AudioPacket.Packet, newest first.
    static func payloads(newest: AudioPacket.Packet, previous: [AudioPacket.Packet],
                         limit: Int = AudioPacket.maxDatagramPlaintext) -> [Data] {
        guard let first = newest.payloads.first else { return [] }
        var payloads = [first]
        var after = newest
        for packet in previous.prefix(maxCopies) {
            let duration = UInt64(packet.framesPerPacket) * 1_000_000 / UInt64(AudioPacket.sampleRate)
            guard packet.sequence &+ 1 == after.sequence, packet.presentationMicros + duration == after.presentationMicros,
                  let payload = packet.payloads.first,
                  AudioPacket.datagramSize(payloads: payloads + [payload]) <= limit else { break }
            payloads.append(payload)
            after = packet
        }
        return payloads
    }
}
