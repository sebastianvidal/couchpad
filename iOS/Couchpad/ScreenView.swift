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
    /// The host's once-a-second verdict on the stream; nil until the first one or after a reset.
    @Published var health: ScreenHealth?

    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var hevc = true
    private var waitingForKeyframe = true
    weak var client: Client?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
    }

    /// A frame went missing on the way: keep the last picture, decode nothing until a
    /// keyframe arrives (the host has been told to send one).
    func markLost() {
        waitingForKeyframe = true
    }

    /// Throws away the decoder state: the next picture must start with a keyframe.
    func reset() {
        layer.flushAndRemoveImage()   // no stale picture under the "waiting" placeholder
        format = nil
        waitingForKeyframe = true
        videoSize = .zero
        health = nil
    }

    func handle(_ packet: Data) {
        guard let frame = ScreenPacket.decode(packet) else { return }
        // Tell the host this frame arrived; it paces the capture by what we have acknowledged,
        // so lag never builds up in the network. Acked even if we can't show it.
        client?.ackFrame(frame.presentationMicros)
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
            requestKeyframe()
            return
        }
        if layer.status == .failed || layer.requiresFlushToResumeDecoding {
            layer.flush()
            waitingForKeyframe = true
            requestKeyframe()
            return
        }
        guard let sample = makeSample(frame, format: format) else { return }
        layer.enqueue(sample)
    }

    private var lastKeyframeRequest = Date.distantPast
    /// At most a few times a second: every frame that arrives while we wait would otherwise
    /// ask again, and each request costs the host a full keyframe.
    private func requestKeyframe() {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 0.2 else { return }
        lastKeyframeRequest = Date()
        client?.send("v k")
    }

    private func makeFormat(_ frame: ScreenPacket.Frame) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        guard !frame.parameterSets.isEmpty, frame.parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }
        // A pointer taken from a Swift array is only valid for the call it is passed to, so
        // each set is copied into memory of our own for the duration of this call.
        let buffers = frame.parameterSets.map { set -> UnsafeMutableBufferPointer<UInt8> in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: set.count)
            _ = buffer.initialize(from: set)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0.baseAddress!) }
        let sizes = buffers.map(\.count)
        let status: OSStatus = pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in
                frame.hevc
                    ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: buffers.count, parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
                    : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: buffers.count, parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
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

/// What the host measures about the stream, for the status dot: `ok` is its own judgement
/// (acks under 50 ms, under two frames lost a second, no skip storm).
struct ScreenHealth: Equatable {
    var ok: Bool
    var ackMs: Int
    var lostPerSecond: Int
    var skippedPercent: Int
    var phones: Int

    var summary: String {
        "\(ackMs) ms · \(lostPerSecond) lost/s · \(skippedPercent)% skipped"
    }
}

/// The picture, letterboxed inside whatever space it is given. `zoom` and `pan` come from
/// the trackpad's pinch (see TrackpadUIView): the picture is scaled about its centre, shifted
/// by `pan`, and clipped to its own frame, so the letterbox never shows picture.
struct ScreenView: UIViewRepresentable {
    @ObservedObject var receiver: ScreenReceiver
    var zoom: CGFloat = 1
    var pan = CGPoint.zero

    func makeUIView(context: Context) -> ScreenUIView {
        let view = ScreenUIView()
        view.layer.masksToBounds = true
        view.layer.addSublayer(receiver.layer)
        return view
    }

    func updateUIView(_ uiView: ScreenUIView, context: Context) {
        uiView.zoom = zoom
        uiView.pan = pan
        uiView.setNeedsLayout()
    }
}

final class ScreenUIView: UIView {
    var zoom: CGFloat = 1
    var pan = CGPoint.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        let frame = ScreenGeometry.zoomed(bounds, zoom: zoom, pan: pan)
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit animation: it must follow the fingers
        for sub in layer.sublayers ?? [] { sub.frame = frame }
        CATransaction.commit()
    }
}

/// Where a zoomed picture sits, shared by the picture (ScreenUIView) and the trackpad
/// mapping touches onto it (TrackpadUIView) so the two agree to the point.
enum ScreenGeometry {
    static let maxZoom: CGFloat = 6

    /// `fit` scaled by `zoom` about its centre and moved by `pan`.
    static func zoomed(_ fit: CGRect, zoom: CGFloat, pan: CGPoint) -> CGRect {
        let size = CGSize(width: fit.width * zoom, height: fit.height * zoom)
        return CGRect(x: fit.midX - size.width / 2 + pan.x, y: fit.midY - size.height / 2 + pan.y,
                      width: size.width, height: size.height)
    }

    /// `pan` limited so the zoomed picture always covers the whole of `fit`: no empty strips.
    static func clampedPan(_ pan: CGPoint, fit: CGRect, zoom: CGFloat) -> CGPoint {
        let maxX = (zoom - 1) * fit.width / 2, maxY = (zoom - 1) * fit.height / 2
        return CGPoint(x: min(max(pan.x, -maxX), maxX), y: min(max(pan.y, -maxY), maxY))
    }
}
