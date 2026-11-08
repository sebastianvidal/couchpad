import SwiftUI
import UIKit

/// The on-screen controller: a floating 8-way stick on the left, a look surface on the
/// right with the buttons over it. Every control reports to `ControllerBridge`, so the same
/// profile that drives a physical pad drives this one, and each button shows what it is
/// bound to. Sits over the computer's picture when that is on.
struct ControllerView: View {
    @ObservedObject var controller: ControllerBridge
    @State private var showBindings = false

    var body: some View {
        GeometryReader { geo in
            let leftWidth = geo.size.width * 0.45
            let rightWidth = geo.size.width - leftWidth
            let button = min(72, max(44, rightWidth * 0.28))
            HStack(spacing: 0) {
                VirtualStick(controller: controller, radius: min(64, leftWidth * 0.3))
                    .frame(width: leftWidth)
                LookSurface(controller: controller)
            }
            // Triggers above bumpers in the corners, the way they sit on a pad, stacked so
            // they stay clear of the menu row even in a narrow pane.
            .overlay(alignment: .topLeading) {
                VStack(spacing: 8) {
                    PadButton(controller: controller, control: .l2, text: "L2", shape: .capsule(width: button * 0.85))
                    PadButton(controller: controller, control: .l1, text: "L1", shape: .capsule(width: button * 0.85))
                }
                .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    PadButton(controller: controller, control: .r2, text: "R2", shape: .capsule(width: button * 0.85))
                    PadButton(controller: controller, control: .r1, text: "R1", shape: .capsule(width: button * 0.85))
                }
                .padding(10)
            }
            .overlay(alignment: .top) {
                HStack(spacing: 8) {
                    PadButton(controller: controller, control: .options, symbol: "ellipsis", shape: .capsule(width: 44))
                    Button {
                        showBindings = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "slider.horizontal.3")
                            Text(controller.profile.name).lineLimit(1)
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(Color(.secondarySystemBackground).opacity(0.9), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Controller bindings")
                    PadButton(controller: controller, control: .menu, symbol: "line.3.horizontal", shape: .capsule(width: 44))
                }
                .padding(.top, 10)
            }
            .overlay(alignment: .bottomTrailing) {
                let step = button * 0.95
                ZStack {
                    PadButton(controller: controller, control: .y, text: "Y", shape: .circle(button)).offset(y: -step)
                    PadButton(controller: controller, control: .x, text: "X", shape: .circle(button)).offset(x: -step)
                    PadButton(controller: controller, control: .b, text: "B", shape: .circle(button)).offset(x: step)
                    PadButton(controller: controller, control: .a, text: "A", shape: .circle(button)).offset(y: step)
                }
                .frame(width: button + 2 * step, height: button + 2 * step)
                .padding(12)
            }
        }
        .onAppear { controller.setVirtualShown(true) }
        .onDisappear { controller.setVirtualShown(false) }
        .sheet(isPresented: $showBindings) {
            NavigationStack {
                ControllerBindingsView(controller: controller)
                    .toolbar { Button("Done") { showBindings = false } }
            }
        }
    }
}

/// A floating stick: the base appears where the finger lands, the knob follows it, and the
/// direction (8-way, so diagonals press two keys) is read from the angle once the finger
/// is far enough from where it started.
private struct VirtualStick: View {
    @ObservedObject var controller: ControllerBridge
    let radius: CGFloat

    @State private var origin: CGPoint?
    @State private var knob = CGPoint.zero   // offset from origin, clamped to the radius
    @State private var held = Set<Control>()
    private let haptic = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear
                if let origin {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 2)
                        .background(Circle().fill(Color(.secondarySystemBackground).opacity(0.5)))
                        .frame(width: radius * 2, height: radius * 2)
                        .position(origin)
                    Circle()
                        .fill(Color.accentColor.opacity(0.85))
                        .frame(width: radius * 0.9, height: radius * 0.9)
                        .position(x: origin.x + knob.x, y: origin.y + knob.y)
                } else {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                        .frame(width: radius * 2, height: radius * 2)
                        .overlay(Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.title3).foregroundStyle(Color.primary.opacity(0.4)))
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.62)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if origin == nil { origin = value.startLocation; haptic.prepare() }
                        guard let origin else { return }
                        var dx = value.location.x - origin.x
                        var dy = value.location.y - origin.y
                        let distance = hypot(dx, dy)
                        if distance > radius { dx *= radius / distance; dy *= radius / distance }
                        knob = CGPoint(x: dx, y: dy)
                        press(directions(dx: dx, dy: dy, distance: distance))
                    }
                    .onEnded { _ in
                        press([])
                        origin = nil
                        knob = .zero
                    }
            )
        }
        .accessibilityLabel("Movement stick")
    }

    /// Eight 45° sectors, centred on the four directions and the diagonals between them.
    private func directions(dx: CGFloat, dy: CGFloat, distance: CGFloat) -> Set<Control> {
        guard distance > radius * 0.3 else { return [] }
        let degrees = (atan2(-dy, dx) * 180 / .pi + 360 + 22.5).truncatingRemainder(dividingBy: 360)
        switch Int(degrees / 45) {
        case 0: return [.leftStickRight]
        case 1: return [.leftStickUp, .leftStickRight]
        case 2: return [.leftStickUp]
        case 3: return [.leftStickUp, .leftStickLeft]
        case 4: return [.leftStickLeft]
        case 5: return [.leftStickDown, .leftStickLeft]
        case 6: return [.leftStickDown]
        default: return [.leftStickDown, .leftStickRight]
        }
    }

    private func press(_ controls: Set<Control>) {
        guard controls != held else { return }
        for control in held.subtracting(controls) { controller.setVirtual(control, pressed: false) }
        for control in controls.subtracting(held) { controller.setVirtual(control, pressed: true) }
        held = controls
        if !controls.isEmpty { haptic.selectionChanged() }
    }
}

/// Drag anywhere here to look around (when the right stick is bound to mouse look). The
/// buttons sit over it and take their own touches.
private struct LookSurface: View {
    @ObservedObject var controller: ControllerBridge
    @State private var last: CGPoint?

    private var looks: Bool { controller.profile[.rightStick] == .mouseLook }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                if looks, last == nil {
                    Image(systemName: "hand.draw")
                        .font(.title3)
                        .foregroundStyle(Color.primary.opacity(0.35))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if let last {
                            controller.addVirtualLook(CGPoint(x: value.location.x - last.x, y: value.location.y - last.y))
                        }
                        last = value.location
                    }
                    .onEnded { _ in last = nil }
            )
            .accessibilityLabel("Look surface")
    }
}

/// One on-screen button: held while the finger is down, with its current binding written
/// under its name so the layout explains itself. Dim when it does nothing.
private struct PadButton: View {
    enum Shape { case circle(CGFloat), capsule(width: CGFloat) }

    @ObservedObject var controller: ControllerBridge
    let control: Control
    var text: String? = nil
    var symbol: String? = nil
    let shape: Shape
    @State private var pressed = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private var action: ControlAction { controller.profile[control] }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 1) {
                if let symbol {
                    Image(systemName: symbol).font(.subheadline.weight(.semibold))
                } else if let text {
                    Text(text).font(isCircle ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                }
                if isCircle, action != .none {
                    Text(action.label)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .opacity(0.8)
                }
            }
            .foregroundStyle(pressed ? Color.white : Color.primary)
            .padding(.horizontal, 4)
        }
        .frame(width: size.width, height: size.height)
        .opacity(action == .none ? 0.45 : 1)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        haptic.impactOccurred()
                        controller.setVirtual(control, pressed: true)
                    }
                }
                .onEnded { _ in
                    pressed = false
                    controller.setVirtual(control, pressed: false)
                }
        )
        .accessibilityLabel("\(control.label): \(action.label)")
    }

    private var isCircle: Bool { if case .circle = shape { return true } else { return false } }

    private var size: CGSize {
        switch shape {
        case .circle(let d): return CGSize(width: d, height: d)
        case .capsule(let w): return CGSize(width: w, height: 34)
        }
    }

    private var fill: Color { pressed ? Color.accentColor : Color(.secondarySystemBackground).opacity(0.9) }

    @ViewBuilder private var background: some View {
        switch shape {
        case .circle: Circle().fill(fill)
        case .capsule: Capsule().fill(fill)
        }
    }
}
