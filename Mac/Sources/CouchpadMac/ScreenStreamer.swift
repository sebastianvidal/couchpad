import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Streams the main display to the phone (with a MacBook's lid closed, VirtualScreen keeps
/// one on): ScreenCaptureKit captures it, the hardware encoder turns it into HEVC (H.264 on Macs
/// without an HEVC encoder), and each frame goes out as a ScreenPacket. Low latency over
/// everything: real-time mode, no frame reordering, an explicit keyframe whenever the phone
/// asks (it does so after it had to drop frames).
///
/// The same stream also captures the Mac's sound while a phone wants it, as Opus packets
/// (AudioEncoder) on their own queue, so sound never waits behind a frame being encoded.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenStreamer()

    /// Encoded frames, on the encoder's thread. The server decides who gets them.
    var onFrame: ((ScreenPacket.Frame) -> Void)?
    /// Opus packets of the Mac's sound, on the audio queue, while a phone wants sound.
    var onAudio: ((AudioPacket.Packet) -> Void)?
    /// Problems worth telling the phone about ("denied", "error …").
    var onStatus: ((String) -> Void)?
    /// Asked before each captured frame is encoded. Returning true skips the frame: a phone
    /// is behind and sending more would only queue up lag. Skipping before the encoder keeps
    /// the reference chain intact, so no keyframe is needed afterwards.
    var isCongested: (() -> Bool)?
    /// Average encoded bytes per frame at the current settings, for sizing the backlog cap.
    private(set) var bytesPerFrame = 40_000
    /// How fast datagrams may leave: three times the bitrate, at least 1 MB/s, so a keyframe
    /// of a few hundred KB still clears in well under a frame interval's worth of lag.
    var paceBytesPerSecond: Double { max(1_000_000, Double(bytesPerFrame * fps) * 3) }
    private var lastKeyframeBytes = 0

    /// Bounds (in points, global display space) of the display being streamed, for mapping
    /// the phone's absolute pointer. Set once the stream starts; the main display before that.
    private(set) var displayBounds = CGDisplayBounds(CGMainDisplayID())

    private let queue = DispatchQueue(label: "couchpad.screen", qos: .userInteractive)
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var hevc = true
    private var frameSize = CGSize.zero
    private var fps = 30
    private var forceKeyframe = true
    private var lastBuffer: CVPixelBuffer?
    private var startedAt = CFAbsoluteTimeGetCurrent()
    private var running = false
    /// Sound: whether any phone wants it, and whether the running stream captures it.
    private var soundWanted = false
    private var streamCapturesAudio = false
    private var audioOutputAdded = false
    private var streamConfig: SCStreamConfiguration?
    /// The audio side, on its own queue. What it needs from the stream (the clock's zero as
    /// host time, which stream is current, whether sound is on) is handed over under
    /// `audioLock`; its `epoch` moves whenever the encoder must start over.
    private let audioQueue = DispatchQueue(label: "couchpad.audio", qos: .userInteractive)
    private let audioEncoder = AudioEncoder()
    private let audioLock = NSLock()
    private var audioShared = (startedAtHost: CACurrentMediaTime(), stream: ObjectIdentifier?.none, on: false, epoch: 0)
    private var encoderEpoch = -1
    private var audioAgeValue = 0.0
    private var audioPacketsValue = 0
    /// What the phones last asked for, while any of them wants the picture. The stream dies
    /// with the display (sleep, lock): as long as this is set it is started again, every
    /// couple of seconds and the moment the screens wake, so the picture comes back on its
    /// own instead of waiting for the phone to toggle it.
    private var wanted: (maxWidth: Int, maxHeight: Int, fps: Int)?
    private var retryPending = false
    /// With the lid closed the picture comes from a screen of our own (VirtualScreen). The lid
    /// is looked at every second while a phone wants the picture or that screen is up.
    private let virtualScreen = VirtualScreen()
    private var lidTimer: DispatchSourceTimer?
    private var lastWantedAt = 0.0
    private var virtualRefusedAt = -Double.infinity
    private var monitorLogged = false
    /// When the displays were woken for a virtual screen still to come (see `checkLid`).
    private var wokeForScreenAt: Double?
    /// ScreenCaptureKit's frame statuses since the stream started, logged a few seconds into
    /// a lid-closed stream: complete, idle (nothing changed), blank, suspended. A virtual
    /// display made while the displays slept gave nothing but blank ones.
    private var statusTally: [Int: Int] = [:]
    /// Why the picture is gone while the lid is closed on battery: told to the phone in
    /// place of whatever error the dying stream reports.
    private var lidNote: String?
    private static let batteryNote = "its lid is closed and it's on battery, so macOS puts it to sleep. Plug it in to use it with the lid closed."
    /// Smoothed timings, for the stats log: how old a frame is when ScreenCaptureKit delivers
    /// it, how long the encoder takes, and how many frames the capture skipped.
    private(set) var captureAge = 0.0
    private(set) var encodeTime = 0.0
    private(set) var skipped = 0
    /// Running totals, for the once-a-second health check (the stats line resets `skipped`).
    private(set) var encodedTotal = 0
    private(set) var skippedTotal = 0
    /// Sound, for the stats line: how old a packet's first sample is when the packet leaves
    /// the encoder (smoothed; includes waiting for the packet to fill), and packets so far.
    var audioAge: Double { audioLock.lock(); defer { audioLock.unlock() }; return audioAgeValue }
    var audioPacketsTotal: Int { audioLock.lock(); defer { audioLock.unlock() }; return audioPacketsValue }
    private var encodeStarts: [Int64: CFAbsoluteTime] = [:]
    /// Bitrate adaptation: the configured rate for the current size, and the share of it in
    /// use. Every lost frame the phone reports cuts the share; quiet stretches restore it.
    private var baseBitrate = 0
    private var rateShare = 1.0
    /// The share in use when loss last struck: recovery heads back to just under it fast,
    /// then creeps above it slowly, instead of climbing straight back into the same wall.
    private var lossShare = 1.0
    private var lastLossAt = 0.0
    private var recentLosses = 0
    private var lastCutAt = 0.0
    private var lastRaiseAt = 0.0
    /// The stats line, resetting the skip counter so it reads as "since the last line".
    func takeStats() -> String {
        let line = String(format: "capture age %.0f ms, encode %.0f ms, skipped %d, rate %.0f%%, keyframe %d KB", captureAge * 1000, encodeTime * 1000, skipped, rateShare * 100, lastKeyframeBytes / 1024)
        skipped = 0
        return line
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    override init() {
        super.init()
        if audioEncoder == nil { NSLog("Sound: no Opus encoder; the picture goes without sound") }
        audioEncoder?.onPacket = { [weak self] packet, firstSampleAt in
            guard let self else { return }
            let age = CACurrentMediaTime() - firstSampleAt
            self.audioLock.lock()
            self.audioAgeValue = self.audioPacketsValue == 0 ? age : self.audioAgeValue * 0.9 + age * 0.1
            self.audioPacketsValue += 1
            self.audioLock.unlock()
            self.onAudio?(packet)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restartIfWanted() }
        }
    }

    /// The display went away under the stream, or starting it failed. Tell the phone once,
    /// then keep trying quietly while someone still wants the picture.
    private func fail(_ message: String) {
        if !retryPending { onStatus?("error \(lidNote ?? message)") }
        stopOnQueue()
        guard wanted != nil, !retryPending else { return }
        retryPending = true
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.retryPending = false
            self?.restartIfWanted()
        }
    }

    private func restartIfWanted() {
        guard let wanted, !running else { return }
        startOnQueue(maxWidth: wanted.maxWidth, maxHeight: wanted.maxHeight, fps: wanted.fps)
    }

    /// Starts (or restarts, if the size changed) a stream that fits in `maxWidth`×`maxHeight`.
    func start(maxWidth: Int, maxHeight: Int, fps: Int) {
        queue.async {
            self.wanted = (maxWidth, maxHeight, fps)
            self.watchLid()
            // A screen just added: the stream starts on it in a moment.
            if self.checkLid() { return }
            self.startOnQueue(maxWidth: maxWidth, maxHeight: maxHeight, fps: fps)
        }
    }

    // MARK: Lid

    private func watchLid() {
        guard lidTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkLid() }
        timer.resume()
        lidTimer = timer
    }

    /// Adds the virtual screen when the lid closes under a phone with the picture, and takes
    /// it away when the lid opens or nobody has watched for a while. True if it did either:
    /// the stream then starts over on the new main screen, once WindowServer has settled.
    @discardableResult
    private func checkLid() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if wanted != nil { lastWantedAt = now }
        let lid = VirtualScreen.lidClosed
        let closed = lid && !VirtualScreen.monitorAttached()
        if lid, !closed, wanted != nil, virtualScreen.displayID == nil, !monitorLogged {
            monitorLogged = true
            NSLog("Screen: lid closed onto a monitor; no virtual display (%@)", VirtualScreen.describeDisplays())
        }
        if !lid { monitorLogged = false }
        let onBattery = closed && virtualScreen.displayID == nil && !VirtualScreen.onACPower
        if onBattery, wanted != nil, lidNote == nil {
            lidNote = Self.batteryNote
            NSLog("Screen: lid closed on battery; the Mac will sleep (no virtual display)")
            onStatus?("error \(Self.batteryNote)")
        } else if !onBattery, lidNote != nil {
            lidNote = nil
        }
        var changed = false
        let needed = closed && !onBattery && wanted != nil && virtualScreen.displayID == nil && now - virtualRefusedAt > 30
        if !needed { wokeForScreenAt = nil }
        if needed, wokeForScreenAt == nil {
            // The lid put the displays to sleep. Wake them first; the screen comes on the
            // next look, a second or two later (one made while they sleep stays blank).
            VirtualScreen.wakeDisplays()
            wokeForScreenAt = now
        } else if needed, let woke = wokeForScreenAt, now - woke >= 1.5 {
            wokeForScreenAt = nil
            if virtualScreen.add() {
                NSLog("Screen: lid closed; showing a %d×%d virtual display", VirtualScreen.width, VirtualScreen.height)
                // Arranged once WindowServer has set the display up; then the stream follows.
                queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    NSLog("Screen: virtual display is %@", self.virtualScreen.arrange())
                }
                queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.restartOnNewScreen() }
                return true
            }
            virtualRefusedAt = now
            NSLog("Screen: lid closed, but macOS refused a virtual display")
        } else if virtualScreen.displayID != nil, !closed || (wanted == nil && now - lastWantedAt > VirtualScreen.linger) {
            virtualScreen.remove()
            NSLog(closed ? "Screen: nobody watching; virtual display removed" : "Screen: lid open; virtual display removed")
            changed = true
        }
        if virtualScreen.displayID == nil, wanted == nil {
            lidTimer?.cancel()
            lidTimer = nil
        }
        if changed, wanted != nil {
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restartOnNewScreen() }
        }
        return changed
    }

    private func restartOnNewScreen() {
        guard let wanted else { return }
        stopOnQueue()
        startOnQueue(maxWidth: wanted.maxWidth, maxHeight: wanted.maxHeight, fps: wanted.fps)
    }

    /// Whether any phone with the picture also wants sound. Applied to a running stream in
    /// place (the picture carries on, no keyframe); a stream starting later picks it up.
    func setSoundWanted(_ wanted: Bool) {
        queue.async {
            guard self.soundWanted != wanted else { return }
            self.soundWanted = wanted
            self.applySound()
        }
    }

    /// Nobody wants the picture any more; also ends any pending restart. A virtual screen
    /// stays a while (see `VirtualScreen.linger`).
    func stop() {
        queue.async {
            self.wanted = nil
            self.stopOnQueue()
        }
    }

    /// The phone lost frames on the way. A run of losses means the link can't carry the
    /// rate; a stray one is just Wi-Fi, and cutting for it only makes the picture blurry.
    func noteLoss(frames: Int) {
        queue.async {
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastLossAt > 2 { self.recentLosses = 0 }
            self.lastLossAt = now
            self.recentLosses += frames
            guard self.recentLosses >= 3, now - self.lastCutAt > 1 else { return }
            self.lastCutAt = now
            self.recentLosses = 0
            self.lossShare = self.rateShare
            self.rateShare = max(0.25, self.rateShare * 0.75)
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
        // The built-in display dropped out from under a mirroring virtual one, which is the
        // main screen now but still in its first mode: fix that first, then come back.
        if virtualScreen.fixModeIfAlone() {
            NSLog("Screen: the built-in display is gone; the virtual display is the only screen now")
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restartOnNewScreen() }
            return
        }
        let displayID = CGMainDisplayID()
        let onVirtual = displayID == virtualScreen.displayID
        displayBounds = CGDisplayBounds(displayID)
        let pixelsWide = CGDisplayPixelsWide(displayID), pixelsHigh = CGDisplayPixelsHigh(displayID)
        let scale = min(1, min(Double(maxWidth) / Double(pixelsWide), Double(maxHeight) / Double(pixelsHigh)))
        // Even dimensions keep every encoder happy.
        let size = CGSize(width: Double(Int(Double(pixelsWide) * scale) / 2 * 2), height: Double(Int(Double(pixelsHigh) * scale) / 2 * 2))
        if running, size == frameSize { forceKeyframe = true; applySound(); return }
        stopOnQueue()
        frameSize = size
        running = true
        forceKeyframe = true
        startedAt = CFAbsoluteTimeGetCurrent()
        statusTally = [:]
        if virtualScreen.displayID != nil {
            let started = startedAt
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.startedAt == started, self.running else { return }
                let names = [0: "complete", 1: "idle", 2: "blank", 3: "suspended", 4: "started", 5: "stopped", -1: "unknown"]
                let tally = self.statusTally.sorted { $0.key < $1.key }.map { "\(names[$0.key] ?? "status \($0.key)") \($0.value)" }
                NSLog("Screen: lid closed, capturing the %@ display, first 3 s: %@", onVirtual ? "virtual" : "built-in",
                      tally.isEmpty ? "no frames at all" : tally.joined(separator: ", "))
            }
        }
        // The same moment on the host clock, which ScreenCaptureKit stamps sound with: a
        // packet's presentation time is then on the picture's clock.
        let startedAtHost = CACurrentMediaTime()
        audioLock.lock()
        audioShared.startedAtHost = startedAtHost
        audioShared.stream = nil
        audioShared.epoch += 1
        audioLock.unlock()

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            self.queue.async {
                guard self.running, self.frameSize == size else { return }
                // A new virtual screen may not be listed yet: wait for it rather than take another.
                guard let display = content?.displays.first(where: { $0.displayID == displayID }) ?? (onVirtual ? nil : content?.displays.first) else {
                    self.fail(error?.localizedDescription ?? "no display")
                    return
                }
                let config = SCStreamConfiguration()
                config.width = Int(size.width)
                config.height = Int(size.height)
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(self.fps))
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                config.showsCursor = true
                config.queueDepth = 3
                let capturesAudio = self.soundWanted && self.audioEncoder != nil
                Self.configureAudio(config, on: capturesAudio)
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    try self.makeEncoder(size: size)
                } catch {
                    self.fail(error.localizedDescription)
                    return
                }
                // The sound output goes on once, whether sound is on or not, so switching it on
                // later is a configuration change only. Should ScreenCaptureKit refuse an audio
                // output on a stream that captures none, it is added when sound is switched on.
                self.audioOutputAdded = false
                if self.audioEncoder != nil {
                    do {
                        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                        self.audioOutputAdded = true
                    } catch {
                        NSLog("Sound: no audio output yet (%@)", error.localizedDescription)
                    }
                }
                self.stream = stream
                self.streamConfig = config
                self.streamCapturesAudio = capturesAudio
                self.publishAudio(stream: stream, on: capturesAudio && self.audioOutputAdded)
                stream.startCapture { [weak self] error in
                    guard let error else { return }
                    self?.queue.async { self?.fail(error.localizedDescription) }
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
        streamConfig = nil
        streamCapturesAudio = false
        audioLock.lock()
        audioShared.stream = nil
        audioShared.on = false
        audioShared.epoch += 1
        audioLock.unlock()
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
            self.encoder = nil
        }
    }

    // MARK: Sound

    private static func configureAudio(_ config: SCStreamConfiguration, on: Bool) {
        config.capturesAudio = on
        config.sampleRate = AudioPacket.sampleRate
        config.channelCount = 2
        // Couchpad makes no sound of its own, but should it ever, the phone must not echo it.
        config.excludesCurrentProcessAudio = true
    }

    /// Tells the audio queue which stream's sound to take, and starts the encoder over.
    private func publishAudio(stream: SCStream?, on: Bool) {
        audioLock.lock()
        audioShared.stream = stream.map(ObjectIdentifier.init)
        audioShared.on = on
        audioShared.epoch += 1
        audioLock.unlock()
    }

    /// Brings the running stream's sound in line with what the phones want, in place:
    /// `updateConfiguration` keeps the picture running and needs no keyframe. If ScreenCaptureKit
    /// won't change it in place, the stream is started over with the new setting.
    private func applySound() {
        let on = soundWanted && audioEncoder != nil
        guard running, let stream, let streamConfig, streamCapturesAudio != on else { return }
        if on, !audioOutputAdded {
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                audioOutputAdded = true
            } catch {
                NSLog("Sound: can't add the audio output (%@); the picture goes without sound", error.localizedDescription)
                return
            }
        }
        streamCapturesAudio = on
        Self.configureAudio(streamConfig, on: on)
        // Stop taking sound at once when it goes off; when it comes on, the first buffers
        // start a fresh timeline (the epoch moves either way).
        publishAudio(stream: stream, on: on)
        stream.updateConfiguration(streamConfig) { [weak self] error in
            guard let error else { return }
            guard let self else { return }
            self.queue.async {
                guard self.stream === stream else { return }
                NSLog("Sound: switching %@ in place failed (%@); restarting the stream", on ? "on" : "off", error.localizedDescription)
                self.stopOnQueue()
                self.restartIfWanted()
            }
        }
    }

    /// Sound buffers, on the audio queue: only from the current stream, and only while sound
    /// is on (buffers may still trickle in just after it was switched off).
    private func handleAudio(_ sample: CMSampleBuffer, from stream: SCStream) {
        guard let audioEncoder else { return }
        audioLock.lock()
        let shared = audioShared
        audioLock.unlock()
        guard shared.on, shared.stream == ObjectIdentifier(stream) else { return }
        if encoderEpoch != shared.epoch {
            encoderEpoch = shared.epoch
            audioEncoder.reset()
        }
        audioEncoder.append(sample, startedAtHost: shared.startedAtHost)
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
        if type == .audio { handleAudio(sampleBuffer, from: stream); return }
        guard type == .screen, running else { return }
        let status = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first?[.status] as? Int
        statusTally[status ?? -1, default: 0] += 1
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // ScreenCaptureKit also delivers "idle" samples with no new content; skip those.
        if let status, status != SCFrameStatus.complete.rawValue, !forceKeyframe { return }
        lastBuffer = buffer
        let age = CACurrentMediaTime() - CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        captureAge = captureAge * 0.9 + age * 0.1
        // Behind? Skip this frame rather than queue it; the next one encodes against the
        // last frame the phone actually got.
        if !forceKeyframe, isCongested?() == true { skipped += 1; skippedTotal += 1; return }
        let now = CFAbsoluteTimeGetCurrent()
        if rateShare < 1, now - lastLossAt > 3 {
            // Quick back up to 85% of where it last broke; past that, 5% every 10 s.
            let ceiling = lossShare * 0.85
            if rateShare < ceiling, now - lastRaiseAt > 3 {
                lastRaiseAt = now
                rateShare = min(ceiling, rateShare * 1.2)
                applyBitrate()
            } else if rateShare >= ceiling, now - lastRaiseAt > 10 {
                lastRaiseAt = now
                rateShare = min(1, rateShare + 0.05)
                applyBitrate()
            }
        }
        encode(buffer, now: now)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard self.stream === stream else { return }   // an old stream going away
            self.fail(error.localizedDescription)
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
        if keyframe { lastKeyframeBytes = length }
        encodedTotal += 1
        let frame = ScreenPacket.Frame(keyframe: keyframe, hevc: hevc, width: Int(dims.width), height: Int(dims.height),
                                       presentationMicros: UInt64(max(0, pts.seconds) * 1_000_000), parameterSets: sets, nalData: nal)
        onFrame?(frame)
    }
}
