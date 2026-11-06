import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Receives the host's screen stream (ScreenPacket frames) and shows it: frames are wrapped
/// into sample buffers and handed to an AVSampleBufferDisplayLayer, which decodes in
/// hardware and draws them as they arrive.
@MainActor
final class ScreenReceiver: ObservableObject {
    /// Size of the pictures being shown, in pixels; .zero until the first keyframe.
    @Published private(set) var videoSize = CGSize.zero
    /// Why there is no picture, as reported by the host ("denied", "error …"), or nil.
    @Published var hostMessage: String?

    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var hevc = true
    private var waitingForKeyframe = true
    weak var client: Client?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
    }

    /// Throws away the decoder state: the next picture must start with a keyframe.
    func reset() {
        layer.flush()
        format = nil
        waitingForKeyframe = true
        videoSize = .zero
    }

    func handle(_ packet: Data) {
        guard let frame = ScreenPacket.decode(packet) else { return }
        if frame.keyframe, !frame.parameterSets.isEmpty {
            if format == nil || hevc != frame.hevc || Int(videoSize.width) != frame.width || Int(videoSize.height) != frame.height {
                layer.flush()
            }
            format = makeFormat(frame)
            hevc = frame.hevc
            waitingForKeyframe = false
            if videoSize != CGSize(width: frame.width, height: frame.height) {
                videoSize = CGSize(width: frame.width, height: frame.height)
            }
            hostMessage = nil
        }
        guard !waitingForKeyframe, let format else {
            client?.send("v k")
            return
        }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            layer.flush()
            waitingForKeyframe = true
            client?.send("v k")
            return
        }
        guard let sample = makeSample(frame, format: format) else { return }
        layer.enqueue(sample)
    }

    private func makeFormat(_ frame: ScreenPacket.Frame) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        let sets = frame.parameterSets.map { [UInt8]($0) }
        let pointers = sets.map { UnsafePointer<UInt8>($0) }   // kept alive by `sets` for this call
        let sizes = sets.map(\.count)
        let status: OSStatus = pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in
                frame.hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        withExtendedLifetime(sets) {}
        return status == noErr ? description : nil
    }

    private func makeSample(_ frame: ScreenPacket.Frame, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = frame.nalData.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = frame.nalData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(frame.presentationMicros), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // Show each frame as soon as it is decoded; latency matters more than cadence here.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [CFMutableDictionary], let first = attachments.first {
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// The picture, letterboxed inside whatever space it is given.
struct ScreenView: UIViewRepresentable {
    @ObservedObject var receiver: ScreenReceiver

    func makeUIView(context: Context) -> ScreenUIView {
        let view = ScreenUIView()
        view.layer.addSublayer(receiver.layer)
        return view
    }

    func updateUIView(_ uiView: ScreenUIView, context: Context) {
        uiView.setNeedsLayout()
    }
}

final class ScreenUIView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in layer.sublayers ?? [] { sub.frame = bounds }
    }
}
