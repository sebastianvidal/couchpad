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
    }

    private func save(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
