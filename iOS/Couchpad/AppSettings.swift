import Foundation
import Combine

final class AppSettings: ObservableObject {
    @Published var sensitivity: Double { didSet { save("sensitivity", sensitivity) } }
    @Published var scrollSpeed: Double { didSet { save("scrollSpeed", scrollSpeed) } }
    @Published var naturalScroll: Bool { didSet { save("naturalScroll", naturalScroll) } }
    @Published var tapToDrag: Bool { didSet { save("tapToDrag", tapToDrag) } }
    @Published var threeFingerSwipes: Bool { didSet { save("threeFingerSwipes", threeFingerSwipes) } }
    @Published var manualHost: String { didSet { save("manualHost", manualHost) } }
    @Published var controllerLookSpeed: Double { didSet { save("controllerLookSpeed", controllerLookSpeed) } }
    @Published var controllerInvertY: Bool { didSet { save("controllerInvertY", controllerInvertY) } }
    @Published var trackpadOnRight: Bool { didSet { save("trackpadOnRight", trackpadOnRight) } }
    @Published var showScreen: Bool { didSet { save("showScreen", showScreen) } }
    /// With the picture on: touching it puts the pointer under the finger instead of the
    /// trackpad's usual relative moves.
    @Published var tapToPoint: Bool { didSet { save("tapToPoint", tapToPoint) } }
    /// Picture resolution as a share of the trackpad's pixels: 0 half, 1 two thirds, 2 full.
    /// Fewer pixels mean smaller frames, which is what latency over Wi-Fi comes down to.
    @Published var screenQuality: Int { didSet { save("screenQuality", screenQuality) } }
    /// The on-screen controller (stick, look surface, buttons) in place of the trackpad.
    @Published var showController: Bool { didSet { save("showController", showController) } }

    init() {
        let d = UserDefaults.standard
        sensitivity = d.object(forKey: "sensitivity") as? Double ?? 2.5
        scrollSpeed = d.object(forKey: "scrollSpeed") as? Double ?? 1.5
        naturalScroll = d.object(forKey: "naturalScroll") as? Bool ?? true
        tapToDrag = d.object(forKey: "tapToDrag") as? Bool ?? true
        threeFingerSwipes = d.object(forKey: "threeFingerSwipes") as? Bool ?? true
        manualHost = d.string(forKey: "manualHost") ?? ""
        controllerLookSpeed = d.object(forKey: "controllerLookSpeed") as? Double ?? 10
        controllerInvertY = d.object(forKey: "controllerInvertY") as? Bool ?? false
        trackpadOnRight = d.object(forKey: "trackpadOnRight") as? Bool ?? false
        showScreen = d.object(forKey: "showScreen") as? Bool ?? false
        tapToPoint = d.object(forKey: "tapToPoint") as? Bool ?? false
        screenQuality = d.object(forKey: "screenQuality") as? Int ?? 1
        showController = d.object(forKey: "showController") as? Bool ?? false
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
