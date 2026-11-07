import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Streams the main display to the phone: ScreenCaptureKit captures it, the hardware encoder
/// turns it into HEVC (H.264 on Macs without an HEVC encoder), and each frame goes out as a
/// ScreenPacket. Low latency over everything: real-time mode, no frame reordering, an
/// explicit keyframe whenever the phone asks (it does so after it had to drop frames).
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenStreamer()

    /// Encoded frames, on the encoder's thread. The server decides who gets them.
    var onFrame: ((ScreenPacket.Frame) -> Void)?
    /// Problems worth telling the phone about ("denied", "error …").
    var onStatus: ((String) -> Void)?
    /// Asked before each captured frame is encoded. Returning true skips the frame: a phone
    /// is behind and sending more would only queue up lag. Skipping before the encoder keeps
    /// the reference chain intact, so no keyframe is needed afterwards.
    var isCongested: (() -> Bool)?
    /// Average encoded bytes per frame at the current settings, for sizing the backlog cap.
    private(set) var bytesPerFrame = 40_000

    /// Bounds (in points, global display space) of the display being streamed, for mapping
    /// the phone's absolute pointer. Set once the stream starts; the main display before that.
    private(set) var displayBounds = CGDisplayBounds(CGMainDisplayID())

    private let queue = DispatchQueue(label: "couchpad.screen")
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var hevc = true
    private var frameSize = CGSize.zero
    private var fps = 30
    private var forceKeyframe = true
    private var lastBuffer: CVPixelBuffer?
    private var startedAt = CFAbsoluteTimeGetCurrent()
    private var running = false
    /// Smoothed timings, for the stats log: how old a frame is when ScreenCaptureKit delivers
    /// it, how long the encoder takes, and how many frames the capture skipped.
    private(set) var captureAge = 0.0
    private(set) var encodeTime = 0.0
    private(set) var skipped = 0
    private var encodeStarts: [Int64: CFAbsoluteTime] = [:]
    /// Bitrate adaptation: the configured rate for the current size, and the share of it in
    /// use. Every lost frame the phone reports cuts the share; quiet stretches restore it.
    private var baseBitrate = 0
    private var rateShare = 1.0
    private var lastLossAt = 0.0
    private var lastRaiseAt = 0.0
    /// The stats line, resetting the skip counter so it reads as "since the last line".
    func takeStats() -> String {
        let line = String(format: "capture age %.0f ms, encode %.0f ms, skipped %d, rate %.0f%%", captureAge * 1000, encodeTime * 1000, skipped, rateShare * 100)
        skipped = 0
        return line
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Starts (or restarts, if the size changed) a stream that fits in `maxWidth`×`maxHeight`.
    func start(maxWidth: Int, maxHeight: Int, fps: Int) {
        queue.async { self.startOnQueue(maxWidth: maxWidth, maxHeight: maxHeight, fps: fps) }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    /// The phone lost a frame on the way: smaller frames are less likely to lose a packet.
    func noteLoss() {
        queue.async {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastLossAt > 0.5 else { return }   // one burst, one cut
            self.lastLossAt = now
            self.rateShare = max(0.25, self.rateShare * 0.7)
            self.applyBitrate()
        }
    }

    private func applyBitrate() {
        guard let encoder, baseBitrate > 0 else { return }
        let bitrate = Int(Double(baseBitrate) * rateShare)
        bytesPerFrame = bitrate / 8 / fps
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate / 8 * 3 / 2, 1] as CFArray)
    }

    private var lastKeyframeAt = 0.0
    func requestKeyframe() {
        queue.async {
            // Several phones, or one phone losing several frames, ask within the same instant:
            // one keyframe serves them all.
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastKeyframeAt > 0.1 else { return }
            self.lastKeyframeAt = now
            self.forceKeyframe = true
            // A still screen produces no new frames; re-encode the last one so the phone
            // gets its keyframe now rather than at the next change.
            if let buffer = self.lastBuffer { self.encode(buffer, now: CFAbsoluteTimeGetCurrent()) }
        }
    }

    private func startOnQueue(maxWidth: Int, maxHeight: Int, fps: Int) {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt the first time; after that the user has to flip the switch.
            CGRequestScreenCaptureAccess()
            onStatus?("denied")
            return
        }
        self.fps = max(10, min(60, fps))
        let displayID = CGMainDisplayID()
        displayBounds = CGDisplayBounds(displayID)
        let pixelsWide = CGDisplayPixelsWide(displayID), pixelsHigh = CGDisplayPixelsHigh(displayID)
        let scale = min(1, min(Double(maxWidth) / Double(pixelsWide), Double(maxHeight) / Double(pixelsHigh)))
        // Even dimensions keep every encoder happy.
        let size = CGSize(width: Double(Int(Double(pixelsWide) * scale) / 2 * 2), height: Double(Int(Double(pixelsHigh) * scale) / 2 * 2))
        if running, size == frameSize { forceKeyframe = true; return }
        stopOnQueue()
        frameSize = size
        running = true
        forceKeyframe = true
        startedAt = CFAbsoluteTimeGetCurrent()

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.frameSize == size else { return }
                guard let display = content?.displays.first(where: { $0.displayID == displayID }) ?? content?.displays.first else {
                    self.onStatus?("error \(error?.localizedDescription ?? "no display")")
                    self.running = false
                    return
                }
                let config = SCStreamConfiguration()
                config.width = Int(size.width)
                config.height = Int(size.height)
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.fps))
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                config.showsCursor = true
                config.queueDepth = 3
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    try self.makeEncoder(size: size)
                } catch {
                    self.onStatus?("error \(error.localizedDescription)")
                    self.running = false
                    return
                }
                self.stream = stream
                stream.startCapture { [weak self] error in
                    guard let error else { return }
                    self?.queue.async {
                        self?.onStatus?("error \(error.localizedDescription)")
                        self?.stopOnQueue()
                    }
                }
            }
        }
    }

    private func stopOnQueue() {
        running = false
        lastBuffer = nil
        if let stream {
            stream.stopCapture { _ in }
            self.stream = nil
        }
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
            self.encoder = nil
        }
    }

    // MARK: Encoder

    private func makeEncoder(size: CGSize) throws {
        var session: VTCompressionSession?
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
                                                codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        hevc = status == noErr
        if !hevc {
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(size.width), height: Int32(size.height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        }
        guard status == noErr, let session else { throw NSError(domain: "Couchpad", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "no video encoder"]) }
        let pixelsPerSecond = Double(size.width * size.height) * Double(fps)
        baseBitrate = Int(max(2_000_000, min(25_000_000, pixelsPerSecond * 0.12)))
        let bitrate = Int(Double(baseBitrate) * rateShare)
        bytesPerFrame = bitrate / 8 / fps
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AllowTemporalCompression: true,
            kVTCompressionPropertyKey_ProfileLevel: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_DataRateLimits: [bitrate / 8 * 3 / 2, 1] as CFArray,   // bytes per 1 s, with headroom for keyframes
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            // Keyframes are many times the size of other frames; the phone asks for one
            // whenever it needs it, so the periodic ones are only a safety net.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 30,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
        ]
        VTSessionSetProperties(session, propertyDictionary: props as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, running, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // ScreenCaptureKit also delivers "idle" samples with no new content; skip those.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue, !forceKeyframe {
            return
        }
        lastBuffer = buffer
        let age = CACurrentMediaTime() - CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        captureAge = captureAge * 0.9 + age * 0.1
        // Behind? Skip this frame rather than queue it; the next one encodes against the
        // last frame the phone actually got.
        if !forceKeyframe, isCongested?() == true { skipped += 1; return }
        let now = CFAbsoluteTimeGetCurrent()
        if rateShare < 1, now - lastLossAt > 5, now - lastRaiseAt > 5 {
            lastRaiseAt = now
            rateShare = min(1, rateShare * 1.25)
            applyBitrate()
        }
        encode(buffer, now: now)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.onStatus?("error \(error.localizedDescription)")
            self.stopOnQueue()
        }
    }

    private func encode(_ buffer: CVPixelBuffer, now: CFAbsoluteTime) {
        guard let encoder else { return }
        let pts = CMTime(seconds: now - startedAt, preferredTimescale: 1_000_000)
        var props: [CFString: Any] = [:]
        if forceKeyframe {
            props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true
            forceKeyframe = false
        }
        let hevc = self.hevc
        encodeStarts[pts.value] = now
        if encodeStarts.count > 64 { encodeStarts.removeAll() }
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props as CFDictionary, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            if let start = self.encodeStarts.removeValue(forKey: CMSampleBufferGetPresentationTimeStamp(sample).value) {
                self.encodeTime = self.encodeTime * 0.9 + (CFAbsoluteTimeGetCurrent() - start) * 0.1
            }
            self.emit(sample, hevc: hevc)
        }
    }

    private func emit(_ sample: CMSampleBuffer, hevc: Bool) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let keyframe = !notSync

        var sets: [Data] = []
        if keyframe {
            var count = 0
            if hevc {
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            } else {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = hevc
                    ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if status == noErr, let pointer { sets.append(Data(bytes: pointer, count: size)) }
            }
        }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr else { return }
        var nal = Data(count: length)
        nal.withUnsafeMutableBytes { dest in
            _ = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: dest.baseAddress!)
        }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let frame = ScreenPacket.Frame(keyframe: keyframe, hevc: hevc, width: Int(dims.width), height: Int(dims.height),
                                       presentationMicros: UInt64(max(0, pts.seconds) * 1_000_000), parameterSets: sets, nalData: nal)
        onFrame?(frame)
    }
}
