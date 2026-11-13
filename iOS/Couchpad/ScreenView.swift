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
        // The sound waits for the picture when the picture is the slower of the two.
        client?.audio.noteVideoFrame(presentationMicros: frame.presentationMicros)
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

/// The picture, filling the trackpad's pane: placed and clipped by `ScreenGeometry`, so at
/// 1× it is letterboxed as before, zoomed in it grows into the empty trackpad around it,
/// and with the keyboard up it keeps the size it has with the keyboard down
/// (`restingHeight`) and is pushed up, its top cut off by the pane. `zoom` and `pan` come
/// from the trackpad's pinch (see TrackpadUIView), which works from the same geometry.
struct ScreenView: UIViewRepresentable {
    @ObservedObject var receiver: ScreenReceiver
    var zoom: CGFloat = 1
    var pan = CGPoint.zero
    /// The pane's height with the keyboard down, or 0, and whether the keyboard is up; see
    /// `ScreenGeometry.KeyboardPush`.
    var restingHeight: CGFloat = 0
    var keyboardUp = false
    /// The picture held at its old size while the Mac reshapes; see `ScreenGeometry.Hold`.
    var hold: ScreenGeometry.Hold?

    func makeUIView(context: Context) -> ScreenUIView {
        let view = ScreenUIView()
        view.layer.masksToBounds = true
        view.videoLayer = receiver.layer
        return view
    }

    func updateUIView(_ uiView: ScreenUIView, context: Context) {
        uiView.zoom = zoom
        uiView.pan = pan
        uiView.videoSize = receiver.videoSize
        uiView.hold = hold
        uiView.push.resting = restingHeight
        uiView.push.keyboardUp = keyboardUp
        uiView.push.settle(pane: uiView.bounds.size)
        uiView.setNeedsLayout()
    }
}

/// Holds the receiver's one picture layer while it is on screen. SwiftUI can make more than
/// one picture view at a time (one it never shows, or an old one kept for an animation),
/// and the layer can only be in one: handed over at creation, it went to whichever view was
/// made last, and when that was not the one on screen the picture stayed empty while the
/// stream ran on. So the view that is in a window takes the layer: at once when it enters
/// one, and on every layout if whoever holds it has left its window.
/// The layer sits in `clipView`, which is the viewport (the part of the pane the picture
/// shows in) with the pane's rounded corners.
final class ScreenUIView: UIView {
    var zoom: CGFloat = 1
    var pan = CGPoint.zero
    var videoSize = CGSize.zero
    var push = ScreenGeometry.KeyboardPush()
    var hold: ScreenGeometry.Hold?
    weak var videoLayer: CALayer?
    private let clipView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipView.isUserInteractionEnabled = false
        clipView.layer.masksToBounds = true
        clipView.layer.cornerRadius = 16
        clipView.layer.cornerCurve = .continuous
        addSubview(clipView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        claimVideoLayer(force: true)
    }

    private func claimVideoLayer(force: Bool = false) {
        guard window != nil, let videoLayer, videoLayer.superlayer !== clipView.layer else { return }
        let holder = videoLayer.superlayer?.delegate as? UIView
        guard force || holder?.window == nil else { return }
        clipView.layer.addSublayer(videoLayer)
        setNeedsLayout()
    }

    /// Runs on every step while SwiftUI animates this view's frame (it moves platform views
    /// a display frame at a time), so the picture follows the pane: with the keyboard
    /// sliding, the pushed amount is read off the pane's height on each step and the
    /// picture keeps its size and rides up or down with the bar.
    override func layoutSubviews() {
        super.layoutSubviews()
        claimVideoLayer()
        let pane = bounds.size
        push.settle(pane: pane)
        let home = ScreenGeometry.home(for: videoSize, in: pane, pushed: push.pushed(pane: pane), hold: hold)
        let viewport = ScreenGeometry.viewport(home: home, in: pane, zoom: zoom)
        // Clamped here too: the trackpad keeps its pan as the fingers left it, and the pane
        // may have changed shape since (the keyboard, a rotation).
        let picture = ScreenGeometry.zoomed(home, zoom: zoom, pan: ScreenGeometry.clampedPan(pan, home: home, in: pane, zoom: zoom))
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit animation: it must follow the fingers
        clipView.frame = viewport
        for sub in clipView.layer.sublayers ?? [] { sub.frame = picture.offsetBy(dx: -viewport.minX, dy: -viewport.minY) }
        CATransaction.commit()
    }
}

/// Where the picture sits in its pane, shared by the picture (ScreenUIView) and the trackpad
/// mapping touches onto it (TrackpadUIView) so the two agree to the point.
///
/// `home` is the picture at 1×. The zoomed picture is `home` scaled about its centre and
/// moved by `pan`. On each axis it stays centred where `home` is (and `pan` is zero there)
/// for as long as it fits in the pane; once it is larger than the pane, it covers the whole
/// pane on that axis and `pan` moves it around within that. So zooming in grows the picture
/// into the empty trackpad around it before anything is cut off.
enum ScreenGeometry {
    static let maxZoom: CGFloat = 6

    /// How much shorter the pane is than with the keyboard down (`resting`, measured then;
    /// 0 where nothing is pushed). Read off the pane's current height, so while the keyboard
    /// slides it follows the pane step by step and the picture keeps its size. Under half a
    /// point is rounding, not a keyboard.
    static func pushed(resting: CGFloat, pane: CGSize) -> CGFloat {
        let pushed = resting - pane.height
        return pushed < 0.5 ? 0 : pushed
    }

    /// Whether the pane being shorter than at rest is the keyboard's doing, and so pushes
    /// the picture up instead of shrinking it. The resting height is measured as soon as a
    /// keyboard-down layout settles, while SwiftUI is still moving the views there a step
    /// at a time: when the pane grows with the keyboard down (the pad band or the docked
    /// key row going away), it is shorter than the new resting height for the whole slide,
    /// and a push then would snap the picture to its final size at once, cut off at the top
    /// until the pane caught up. So the push only holds while the keyboard is up, and after
    /// it has gone until the pane is back at its resting height; otherwise the picture
    /// follows the pane as it always did. ScreenUIView and TrackpadUIView each keep one and
    /// settle it on the same inputs and bounds, so they agree.
    struct KeyboardPush: Equatable {
        var resting: CGFloat = 0
        var keyboardUp = false
        private(set) var holding = false

        /// Called on every layout step and whenever the inputs change.
        mutating func settle(pane: CGSize) {
            if keyboardUp {
                holding = true
            } else if ScreenGeometry.pushed(resting: resting, pane: pane) == 0 {
                holding = false
            }
        }

        func pushed(pane: CGSize) -> CGFloat {
            holding ? ScreenGeometry.pushed(resting: resting, pane: pane) : 0
        }
    }

    /// Whether `request` (in pixels) needs no more of the stream than `last` already gives:
    /// the picture of `video`'s shape the host would fit into it is no bigger, to within 1%
    /// on each side, than the one it fits into `last`. A smaller or equal picture is served
    /// well enough by the stream there is (scaled down on the phone), and asking for it
    /// would only restart the stream. With no picture yet the shape is unknown and the
    /// boxes themselves are compared, which is safe: a box no bigger than the last one can
    /// never need a bigger picture.
    static func needsNoMore(_ video: CGSize, in request: CGSize, than last: CGSize) -> Bool {
        guard request.width > 0, request.height > 0, last.width > 0, last.height > 0 else { return false }
        func fit(_ box: CGSize) -> CGSize {
            guard video.width > 0, video.height > 0 else { return box }
            let scale = min(box.width / video.width, box.height / video.height)
            return CGSize(width: video.width * scale, height: video.height * scale)
        }
        let wanted = fit(request), given = fit(last)
        return wanted.width <= given.width * 1.01 && wanted.height <= given.height * 1.01
    }

    /// The picture kept at the size it had before the pane changed shape in the same window
    /// (the pad or the key row coming or going), while a Mac with no screen of its own
    /// reshapes its desktop for the new pane (ContentView's `pictureHold`). Fitted at once,
    /// the old-shaped picture shrank into the new pane, then grew again when the new shape
    /// arrived a second later. `video` is the picture it was taken for: any other picture is
    /// fitted as usual.
    struct Hold: Equatable {
        var video: CGSize
        var size: CGSize
    }

    /// The picture at 1×: aspect-fitted into the pane as if the pane were `pushed` points
    /// taller, which is what it is without the keyboard. No taller than the pane, it is
    /// centred in it; taller, its bottom sits at the pane's bottom and its top is cut off
    /// above the pane. With `pushed` zero this is the plain aspect-fit rect.
    /// With a `hold` for this picture and nothing pushed (the keyboard always wins), the
    /// picture keeps the held size, top edge where the pane's is and centred across: the
    /// pane's top stays put when the pad or the key row comes or goes under it, so the
    /// picture stays where it was on screen, cut off by a pane that got shorter or with a
    /// gap under it in one that got taller.
    static func home(for video: CGSize, in pane: CGSize, pushed: CGFloat = 0, hold: Hold? = nil) -> CGRect {
        guard video.width > 0, video.height > 0, pane.width > 0, pane.height > 0 else { return CGRect(origin: .zero, size: pane) }
        if let hold, hold.video == video, pushed <= 0 {
            return CGRect(x: (pane.width - hold.size.width) / 2, y: 0, width: hold.size.width, height: hold.size.height)
        }
        let scale = min(pane.width / video.width, (pane.height + max(0, pushed)) / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        let y = size.height <= pane.height ? (pane.height - size.height) / 2 : pane.height - size.height
        return CGRect(x: (pane.width - size.width) / 2, y: y, width: size.width, height: size.height)
    }

    /// `home` scaled by `zoom` about its centre and moved by `pan`.
    static func zoomed(_ home: CGRect, zoom: CGFloat, pan: CGPoint) -> CGRect {
        let size = CGSize(width: home.width * zoom, height: home.height * zoom)
        return CGRect(x: home.midX - size.width / 2 + pan.x, y: home.midY - size.height / 2 + pan.y,
                      width: size.width, height: size.height)
    }

    /// The part of the pane the picture shows in at `zoom`, which is what it is clipped to:
    /// the unpanned picture, cut to the pane. It grows with the zoom until it is the whole
    /// pane. (`home` is either centred or covers the pane from its bottom up, so the unpanned
    /// picture always covers the pane on any axis where it is larger than it.)
    static func viewport(home: CGRect, in pane: CGSize, zoom: CGFloat) -> CGRect {
        let cut = zoomed(home, zoom: zoom, pan: .zero).intersection(CGRect(origin: .zero, size: pane))
        return cut.isNull ? .zero : cut
    }

    /// `pan` limited so the zoomed picture covers the whole viewport: zero on an axis where
    /// the picture fits in the pane, and no empty strip inside the pane on one where it is
    /// larger. The limits meet at zero when the picture just fills the pane, so the pan
    /// moves on smoothly as the zoom grows past that point.
    static func clampedPan(_ pan: CGPoint, home: CGRect, in pane: CGSize, zoom: CGFloat) -> CGPoint {
        let view = viewport(home: home, in: pane, zoom: zoom)
        let still = zoomed(home, zoom: zoom, pan: .zero)
        guard !view.isEmpty else { return .zero }
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            low <= high ? min(max(value, low), high) : (low + high) / 2
        }
        return CGPoint(x: clamp(pan.x, view.maxX - still.maxX, view.minX - still.minX),
                       y: clamp(pan.y, view.maxY - still.maxY, view.minY - still.minY))
    }
}
