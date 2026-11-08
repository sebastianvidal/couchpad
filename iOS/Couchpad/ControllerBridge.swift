import Combine
import CoreGraphics
import Foundation
import GameController

/// Forwards a physical controller attached to the iPhone (Backbone, a Bluetooth PS/Xbox
/// pad, …) to the computer as keys and mouse, so any game that accepts keyboard + mouse
/// plays from the couch. The computer never sees a gamepad: macOS has no public way to
/// create one, so this is the honest version.
///
/// What each control does comes from the user's ControllerProfile (presets: FPS, MapleStory,
/// Arrows), edited in Settings → Controller bindings.
///
/// The on-screen controller (`ControllerView`) is a second source of the same controls:
/// it reports which virtual buttons are down and how far the look surface was dragged,
/// and the same loop turns both into keys and mouse, so one profile drives both.
@MainActor
final class ControllerBridge: ObservableObject {
    @Published private(set) var controllerName: String?
    /// Per-control name and SF Symbol as the connected pad reports them (✕ ○ △ □ on a
    /// PlayStation layout, A B X Y on Xbox, LB/RB vs L1/R1, …). Empty when nothing is connected.
    @Published private(set) var labels: [Control: (name: String, symbol: String?)] = [:]
    @Published var profile = ControllerProfile.load() {
        didSet {
            profile.save()
            releaseAll()   // old bindings may be held; start clean under the new ones
        }
    }

    weak var client: Client?
    weak var settings: AppSettings?

    private var controller: GCController?
    private var timer: Timer?
    /// The on-screen controller's state, merged with the physical pad's every tick.
    private var virtualPressed = Set<Control>()
    private var virtualLook = CGPoint.zero
    private var virtualShown = false
    private var heldKeys = Set<Int>()
    private var leftDown = false
    private var rightDown = false
    private var lookRemainder = CGPoint.zero
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                if let controller = note.object as? GCController { self?.attach(controller) }
            }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                if let controller = note.object as? GCController, controller === self?.controller { self?.detach() }
            }
        })
        if let existing = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            attach(existing)
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    private func attach(_ controller: GCController) {
        guard controller.extendedGamepad != nil else { return }
        self.controller = controller
        controllerName = controller.vendorName ?? "Controller"
        labels = ControllerBridge.labels(for: controller.extendedGamepad!)
        startTicking()
    }

    private func detach() {
        releaseAll()
        controller = nil
        controllerName = nil
        labels = [:]
        if !virtualShown { stopTicking() }
    }

    /// Poll at 60 Hz: simpler than per-element handlers and the sticks need a frame clock anyway.
    private func startTicking() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTicking() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: On-screen controller

    /// The on-screen controller is on screen: keep the loop running for it.
    func setVirtualShown(_ shown: Bool) {
        virtualShown = shown
        if shown {
            startTicking()
        } else {
            virtualPressed.removeAll()
            virtualLook = .zero
            if controller == nil { stopTicking(); releaseAll() }
        }
    }

    /// A virtual button or stick direction went down or up.
    func setVirtual(_ control: Control, pressed: Bool) {
        if pressed { virtualPressed.insert(control) } else { virtualPressed.remove(control) }
    }

    /// The look surface was dragged by `delta` points; consumed by the next tick.
    func addVirtualLook(_ delta: CGPoint) {
        virtualLook.x += delta.x
        virtualLook.y += delta.y
    }

    /// The pad's own names for its buttons, so the UI matches what is printed on the plastic.
    private static func labels(for pad: GCExtendedGamepad) -> [Control: (name: String, symbol: String?)] {
        func entry(_ element: GCControllerElement?, fallback: String) -> (String, String?) {
            (element?.localizedName ?? fallback, element?.sfSymbolsName)
        }
        var out: [Control: (name: String, symbol: String?)] = [
            .a: entry(pad.buttonA, fallback: "A"),
            .b: entry(pad.buttonB, fallback: "B"),
            .x: entry(pad.buttonX, fallback: "X"),
            .y: entry(pad.buttonY, fallback: "Y"),
            .l1: entry(pad.leftShoulder, fallback: "L1"),
            .r1: entry(pad.rightShoulder, fallback: "R1"),
            .l2: entry(pad.leftTrigger, fallback: "L2"),
            .r2: entry(pad.rightTrigger, fallback: "R2"),
            .menu: entry(pad.buttonMenu, fallback: "Menu"),
        ]
        if let options = pad.buttonOptions { out[.options] = entry(options, fallback: "Options") }
        if let l3 = pad.leftThumbstickButton { out[.l3] = entry(l3, fallback: "L3") }
        if let r3 = pad.rightThumbstickButton { out[.r3] = entry(r3, fallback: "R3") }
        return out
    }

    /// Display name for a control: the pad's own when connected, a generic one otherwise.
    func name(for control: Control) -> String {
        labels[control]?.name ?? control.label
    }

    func symbol(for control: Control) -> String? {
        labels[control]?.symbol
    }

    /// Lets go of everything, e.g. when the app leaves the foreground.
    func releaseAll() {
        for code in heldKeys { client?.send("k \(code) 0") }
        heldKeys.removeAll()
        if leftDown { client?.send("b l 0"); leftDown = false }
        if rightDown { client?.send("b r 0"); rightDown = false }
    }

    private func tick() {
        guard let client, client.isConnected, controller?.extendedGamepad != nil || virtualShown else {
            if !heldKeys.isEmpty || leftDown || rightDown { releaseAll() }
            virtualLook = .zero
            return
        }

        var pressed = virtualPressed
        var look = CGPoint.zero

        if let pad = controller?.extendedGamepad {
            let ls = pad.leftThumbstick
            if ls.yAxis.value > 0.5 { pressed.insert(.leftStickUp) }
            if ls.yAxis.value < -0.5 { pressed.insert(.leftStickDown) }
            if ls.xAxis.value < -0.5 { pressed.insert(.leftStickLeft) }
            if ls.xAxis.value > 0.5 { pressed.insert(.leftStickRight) }
            if pad.dpad.up.isPressed { pressed.insert(.dpadUp) }
            if pad.dpad.down.isPressed { pressed.insert(.dpadDown) }
            if pad.dpad.left.isPressed { pressed.insert(.dpadLeft) }
            if pad.dpad.right.isPressed { pressed.insert(.dpadRight) }
            if pad.buttonA.isPressed { pressed.insert(.a) }
            if pad.buttonB.isPressed { pressed.insert(.b) }
            if pad.buttonX.isPressed { pressed.insert(.x) }
            if pad.buttonY.isPressed { pressed.insert(.y) }
            if pad.leftShoulder.isPressed { pressed.insert(.l1) }
            if pad.rightShoulder.isPressed { pressed.insert(.r1) }
            if pad.leftTrigger.isPressed { pressed.insert(.l2) }
            if pad.rightTrigger.isPressed { pressed.insert(.r2) }
            if pad.leftThumbstickButton?.isPressed == true { pressed.insert(.l3) }
            if pad.rightThumbstickButton?.isPressed == true { pressed.insert(.r3) }
            if pad.buttonMenu.isPressed { pressed.insert(.menu) }
            if pad.buttonOptions?.isPressed == true { pressed.insert(.options) }

            // The right stick is either mouse look or nothing (bind it to a key to use it as a button).
            let rs = pad.rightThumbstick
            switch profile[.rightStick] {
            case .mouseLook:
                let speed = CGFloat(settings?.controllerLookSpeed ?? 10)
                let invert: CGFloat = settings?.controllerInvertY == true ? 1 : -1
                look = CGPoint(x: curve(CGFloat(rs.xAxis.value)) * speed, y: curve(CGFloat(rs.yAxis.value)) * speed * invert)
            case .key, .mouseLeft, .mouseRight:
                if abs(rs.xAxis.value) > 0.5 || abs(rs.yAxis.value) > 0.5 { pressed.insert(.rightStick) }
            case .none:
                break
            }
        }

        // The on-screen look surface is a finger on glass, so it moves like the trackpad:
        // pointer speed, no inversion.
        if virtualLook != .zero {
            if case .mouseLook = profile[.rightStick] {
                let speed = CGFloat(settings?.sensitivity ?? 2.5)
                look.x += virtualLook.x * speed
                look.y += virtualLook.y * speed
            }
            virtualLook = .zero
        }

        var keys = Set<Int>()
        var left = false, right = false
        for control in pressed {
            switch profile[control] {
            case .none, .mouseLook: break
            case .key(let code): keys.insert(code)
            case .mouseLeft: left = true
            case .mouseRight: right = true
            }
        }

        for code in heldKeys.subtracting(keys) { client.send("k \(code) 0") }
        for code in keys.subtracting(heldKeys) { client.send("k \(code) 1") }
        heldKeys = keys
        if left != leftDown { client.send("b l \(left ? 1 : 0)"); leftDown = left }
        if right != rightDown { client.send("b r \(right ? 1 : 0)"); rightDown = right }

        let dx = look.x + lookRemainder.x
        let dy = look.y + lookRemainder.y
        let ix = Int(dx.rounded(.towardZero))
        let iy = Int(dy.rounded(.towardZero))
        lookRemainder = CGPoint(x: dx - CGFloat(ix), y: dy - CGFloat(iy))
        if ix != 0 || iy != 0 { client.send("m \(ix) \(iy)") }
    }

    private func curve(_ v: CGFloat) -> CGFloat {
        let dead: CGFloat = 0.15
        guard abs(v) > dead else { return 0 }
        let t = (abs(v) - dead) / (1 - dead)
        return (v < 0 ? -1 : 1) * t * t
    }
}
