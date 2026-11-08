import SwiftUI
import UIKit

/// One finger moves, tap clicks, two-finger tap right-clicks, two fingers scroll,
/// tap-then-touch-and-hold drags, three-finger swipes are system gestures
/// (Mission Control, App Exposé, Spaces on the Mac; Task View etc. on Windows).
/// With the picture underneath, a pinch zooms it (moving the pinch looks around; pinching
/// back out resets), reported through `onZoom` so the picture can follow.
struct TrackpadView: UIViewRepresentable {
    let client: Client
    let settings: AppSettings
    /// When the host's picture is underneath, touches point at it: the pointer goes where
    /// the finger is (letterboxed to `videoSize`) instead of moving by deltas.
    var videoSize = CGSize.zero
    /// Size of the picture underneath, whether or not touches point at it; .zero without one.
    var pictureSize = CGSize.zero
    var videoTopLeading = false
    var onZoom: ((CGFloat, CGPoint) -> Void)?

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.client = client
        view.settings = settings
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.videoSize = videoSize
        uiView.pictureSize = pictureSize
        uiView.videoTopLeading = videoTopLeading
        uiView.onZoom = onZoom
        if pictureSize == .zero { uiView.resetZoom() }   // the picture went away; the next one starts at 1×
    }
}

final class TrackpadUIView: UIView {
    weak var client: Client?
    weak var settings: AppSettings?
    var videoSize = CGSize.zero
    var pictureSize = CGSize.zero
    /// Whether the picture is pinned to the top-left corner rather than centered.
    var videoTopLeading = false
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    private var absolute: Bool { videoSize.width > 0 && videoSize.height > 0 }

    /// How far the picture is zoomed in and how far it is shifted from centre (points).
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    /// What two fingers are doing: nothing decided yet, scrolling, or pinching. Decided by
    /// whichever grows first, the distance between them or their common movement, so a
    /// scroll never zooms and a pinch never scrolls the page under it.
    private enum TwoFingers { case undecided, scroll, pinch }
    private var twoFingers = TwoFingers.undecided
    private var pinchDistance: CGFloat = 0
    private var pinchCentroid = CGPoint.zero
    private var pendingScroll = CGPoint.zero

    /// Where a picture of `size` sits inside this view (aspect-fit, before zoom).
    private func fitRect(_ size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        if videoTopLeading { return CGRect(origin: .zero, size: fitted) }
        return CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    /// Where the picture is right now, zoom included, for mapping touches to it.
    private var videoRect: CGRect {
        guard absolute else { return bounds }
        return ScreenGeometry.zoomed(fitRect(videoSize), zoom: zoom, pan: pan)
    }

    /// Back to 1×. Quietly: this runs from `updateUIView`, where a SwiftUI state change would
    /// be dropped; ContentView resets its own copy when the picture goes away.
    func resetZoom() {
        zoom = 1
        pan = .zero
    }

    private var twoTouchPoints: (CGPoint, CGPoint)? {
        guard active.count == 2 else { return nil }
        let points = Array(active.values)
        return (points[0], points[1])
    }

    /// Two fingers moved by `delta`: scroll, or pinch the picture.
    private func handleTwoFingers(_ delta: CGPoint) {
        guard pictureSize != .zero, let (a, b) = twoTouchPoints else { sendScroll(delta); return }
        let distance = hypot(a.x - b.x, a.y - b.y)
        let centre = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        switch twoFingers {
        case .undecided:
            pendingScroll.x += delta.x
            pendingScroll.y += delta.y
            let spread = abs(distance - pinchDistance)
            let moved = hypot(centre.x - pinchCentroid.x, centre.y - pinchCentroid.y)
            if spread > 10, spread > moved {
                twoFingers = .pinch
                pinchDistance = distance
                pinchCentroid = centre
            } else if moved > 10 {
                twoFingers = .scroll
                sendScroll(pendingScroll)   // nothing was lost while we made up our mind
            }
        case .scroll:
            sendScroll(delta)
        case .pinch:
            guard pinchDistance > 0 else { pinchDistance = distance; return }
            let fit = fitRect(pictureSize)
            let before = ScreenGeometry.zoomed(fit, zoom: zoom, pan: pan)
            var newZoom = min(ScreenGeometry.maxZoom, zoom * distance / pinchDistance)
            if newZoom < 1.03 { newZoom = 1 }   // pinched back out: snap home
            // The spot under the fingers stays under them: it moves with the pinch's centre.
            let spot = CGPoint(x: (pinchCentroid.x - before.minX) / zoom, y: (pinchCentroid.y - before.minY) / zoom)
            let origin = CGPoint(x: centre.x - spot.x * newZoom, y: centre.y - spot.y * newZoom)
            let home = ScreenGeometry.zoomed(fit, zoom: newZoom, pan: .zero)
            zoom = newZoom
            pan = newZoom == 1 ? .zero : ScreenGeometry.clampedPan(CGPoint(x: origin.x - home.minX, y: origin.y - home.minY), fit: fit, zoom: newZoom)
            pinchDistance = distance
            pinchCentroid = centre
            onZoom?(zoom, pan)
        }
    }

    private func sendPointer(at point: CGPoint) {
        let r = videoRect
        let fx = min(max((point.x - r.minX) / r.width, 0), 1)
        let fy = min(max((point.y - r.minY) / r.height, 0), 1)
        client?.send(String(format: "M %.4f %.4f", fx, fy))
    }

    private var active: [UITouch: CGPoint] = [:]
    private var startTime: TimeInterval = 0
    private var maxTouches = 0
    private var travel: CGFloat = 0
    private var lastTapTime: TimeInterval = 0
    private var dragging = false
    private var gestureStart = CGPoint.zero   // centroid when a third finger landed
    private var gestureLast = CGPoint.zero
    private var moveRemainder = CGPoint.zero
    private var scrollRemainder = CGPoint.zero
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = Date().timeIntervalSince1970
        if active.isEmpty {
            startTime = now
            maxTouches = 0
            travel = 0
            if settings?.tapToDrag == true, now - lastTapTime < 0.3 {
                dragging = true
                client?.send("b l 1")
                haptic.impactOccurred()
            }
        }
        for touch in touches { active[touch] = touch.location(in: self) }
        maxTouches = max(maxTouches, active.count)
        if absolute, active.count == 1, let point = active.values.first {
            sendPointer(at: point)   // so a tap clicks what is under the finger
        }
        if active.count == 2, let (a, b) = twoTouchPoints {
            twoFingers = .undecided
            pinchDistance = hypot(a.x - b.x, a.y - b.y)
            pinchCentroid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            pendingScroll = .zero
        }
        if active.count == 3 {
            gestureStart = centroid()
            gestureLast = gestureStart
        }
    }

    private func centroid() -> CGPoint {
        let points = active.values
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var delta = CGPoint.zero
        var moved = 0
        for touch in touches {
            guard let previous = active[touch] else { continue }
            let point = touch.location(in: self)
            delta.x += point.x - previous.x
            delta.y += point.y - previous.y
            active[touch] = point
            moved += 1
        }
        guard moved > 0 else { return }
        delta.x /= CGFloat(moved)
        delta.y /= CGFloat(moved)
        travel += hypot(delta.x, delta.y)

        if maxTouches >= 3 {
            // A three-finger gesture: nothing moves or scrolls until all fingers lift.
            gestureLast = centroid()
        } else if active.count == 1 {
            if absolute, let point = active.values.first {
                sendPointer(at: point)
            } else {
                sendMove(delta)
            }
        } else if active.count >= 2 {
            handleTwoFingers(delta)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches { active.removeValue(forKey: touch) }
        guard active.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let duration = now - startTime
        if dragging {
            dragging = false
            client?.send("b l 0")
        } else if maxTouches >= 3 {
            finishSwipe()
        } else if duration < 0.25, travel < 12 {
            if maxTouches == 1 {
                client?.send("c l")
                lastTapTime = now
                haptic.impactOccurred()
            } else if maxTouches == 2, twoFingers != .pinch {
                client?.send("c r")
                haptic.impactOccurred()
            }
        }
    }

    private func finishSwipe() {
        guard settings?.threeFingerSwipes != false else { return }
        let dx = gestureLast.x - gestureStart.x
        let dy = gestureLast.y - gestureStart.y
        guard max(abs(dx), abs(dy)) > 50 else { return }
        let direction: String
        if abs(dy) >= abs(dx) {
            direction = dy < 0 ? "up" : "down"
        } else {
            direction = dx < 0 ? "left" : "right"
        }
        client?.send("g \(direction)")
        haptic.impactOccurred()
    }

    private func sendMove(_ delta: CGPoint) {
        let scale = CGFloat(settings?.sensitivity ?? 2.5)
        let fx = delta.x * scale + moveRemainder.x
        let fy = delta.y * scale + moveRemainder.y
        let ix = Int(fx.rounded(.towardZero))
        let iy = Int(fy.rounded(.towardZero))
        moveRemainder = CGPoint(x: fx - CGFloat(ix), y: fy - CGFloat(iy))
        if ix != 0 || iy != 0 { client?.send("m \(ix) \(iy)") }
    }

    private func sendScroll(_ delta: CGPoint) {
        let scale = CGFloat(settings?.scrollSpeed ?? 1.5)
        let direction: CGFloat = settings?.naturalScroll == false ? -1 : 1
        let fx = delta.x * scale * direction + scrollRemainder.x
        let fy = delta.y * scale * direction + scrollRemainder.y
        let ix = Int(fx.rounded(.towardZero))
        let iy = Int(fy.rounded(.towardZero))
        scrollRemainder = CGPoint(x: fx - CGFloat(ix), y: fy - CGFloat(iy))
        if ix != 0 || iy != 0 { client?.send("s \(ix) \(iy)") }
    }
}
