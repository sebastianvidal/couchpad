import SwiftUI
import UIKit

/// One finger moves, tap clicks, two-finger tap right-clicks, two fingers scroll,
/// tap-then-touch-and-hold drags, three-finger swipes are system gestures
/// (Mission Control, App Exposé, Spaces on the Mac; Task View etc. on Windows).
struct TrackpadView: UIViewRepresentable {
    let client: Client
    let settings: AppSettings
    /// When the host's picture is underneath, touches point at it: the pointer goes where
    /// the finger is (letterboxed to `videoSize`) instead of moving by deltas.
    var videoSize = CGSize.zero
    var videoTopLeading = false

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.client = client
        view.settings = settings
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.videoSize = videoSize
        uiView.videoTopLeading = videoTopLeading
    }
}

final class TrackpadUIView: UIView {
    weak var client: Client?
    weak var settings: AppSettings?
    var videoSize = CGSize.zero
    /// Whether the picture is pinned to the top-left corner rather than centered.
    var videoTopLeading = false
    private var absolute: Bool { videoSize.width > 0 && videoSize.height > 0 }

    /// Where the picture sits inside this view (aspect-fit), for mapping touches to it.
    private var videoRect: CGRect {
        guard absolute, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        if videoTopLeading { return CGRect(origin: .zero, size: size) }
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
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
            sendScroll(delta)
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
            } else if maxTouches == 2 {
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
