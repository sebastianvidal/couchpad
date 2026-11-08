import SwiftUI
import UIKit

/// The on-screen controller, in the key strip's place and style: a stick fixed on the left,
/// the face buttons in a diamond on the right, and a row of seven programmable keys along
/// the top (the pad's bumpers, triggers, stick clicks and menu, each showing its binding). Like a hand-held console, the picture (or trackpad) sits above it. Every
/// control reports to `ControllerBridge`, so the profile that drives a physical pad drives
/// this one, and each button shows what it is bound to.
struct ControllerView: View {
    @ObservedObject var controller: ControllerBridge
    /// Height of one of the four rows; nil fills whatever height the parent gives.
    var rowHeight: CGFloat? = nil

    private let gap: CGFloat = 4
    private let columns: CGFloat = 7
    private let rows: CGFloat = 4
    /// The programmable row: labelled by what they do, tagged with the pad control they are.
    static let topRow: [(Control, String)] = [(.l1, "L1"), (.l2, "L2"), (.l3, "L3"), (.menu, "menu"), (.options, "opt"), (.r1, "R1"), (.r2, "R2")]

    /// Fixed total height for a given row height, so the parent can lay out around it.
    static func height(rowHeight: CGFloat) -> CGFloat { 4 * rowHeight + 3 * 4 }

    var body: some View {
        GeometryReader { geo in
            let unit = (geo.size.width - gap * (columns - 1)) / columns
            // Keys stay key-shaped: however tall the column, a row is at most 1.2 keys high.
            let row = min(unit * 1.2, rowHeight ?? max(28, (geo.size.height - gap * (rows - 1)) / rows))
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    ForEach(ControllerView.topRow, id: \.0) { control, tag in
                        PadKey(controller: controller, control: control, tag: tag)
                            .frame(width: unit, height: row)
                    }
                }
                HStack(spacing: gap) {
                    VirtualStick(controller: controller)
                        .frame(width: unit * 3 + gap * 2, height: row * 3 + gap * 2)
                    ZStack {
                        key(.y, "Y", width: unit, height: row).offset(y: -(row + gap))
                        key(.x, "X", width: unit, height: row).offset(x: -(unit + gap))
                        key(.b, "B", width: unit, height: row).offset(x: unit + gap)
                        key(.a, "A", width: unit, height: row).offset(y: row + gap)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: row * 3 + gap * 2)
            }
            // Pinned to the top under a picture; centred when it has a whole half to itself.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rowHeight == nil ? .center : .top)
        }
        .frame(height: rowHeight.map { ControllerView.height(rowHeight: $0) })
        .onAppear { controller.setVirtualShown(true) }
        .onDisappear { controller.setVirtualShown(false) }
    }

    private func key(_ control: Control, _ text: String? = nil, symbol: String? = nil, width: CGFloat, height: CGFloat) -> some View {
        PadKey(controller: controller, control: control, text: text, symbol: symbol)
            .frame(width: width, height: height)
    }
}

/// A stick in a key-styled well: the knob follows the thumb and the direction (8-way, so
/// diagonals press two keys) is read from its angle once it is far enough from centre.
private struct VirtualStick: View {
    @ObservedObject var controller: ControllerBridge
    @State private var knob = CGPoint.zero   // offset from centre, clamped to the travel
    @State private var active = false
    @State private var held = Set<Control>()
    private let haptic = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let knobSize = side * 0.42
            let travel = (side - knobSize) / 2
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                Circle()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1.5)
                    .frame(width: side * 0.86, height: side * 0.86)
                Circle()
                    .fill(active ? Color.accentColor : Color.primary.opacity(0.25))
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knob.x, y: knob.y)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if !active { active = true; haptic.prepare() }
                        var dx = value.location.x - geo.size.width / 2
                        var dy = value.location.y - geo.size.height / 2
                        let distance = hypot(dx, dy)
                        if distance > travel { dx *= travel / distance; dy *= travel / distance }
                        knob = CGPoint(x: dx, y: dy)
                        press(directions(dx: dx, dy: dy, distance: distance, travel: travel))
                    }
                    .onEnded { _ in
                        press([])
                        active = false
                        knob = .zero
                    }
            )
        }
        .accessibilityLabel("Movement stick")
    }

    /// Eight 45° sectors, centred on the four directions and the diagonals between them.
    private func directions(dx: CGFloat, dy: CGFloat, distance: CGFloat, travel: CGFloat) -> Set<Control> {
        guard distance > travel * 0.3 else { return [] }
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

/// One pad button in the key strip's style: held while the finger is down, its binding
/// written under its name when there is room. Dim when it does nothing.
private struct PadKey: View {
    @ObservedObject var controller: ControllerBridge
    let control: Control
    var text: String? = nil
    var symbol: String? = nil
    /// Programmable key: the binding is the label, this small tag says which control it is.
    var tag: String? = nil
    @State private var pressed = false
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private var action: ControlAction { controller.profile[control] }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(pressed ? Color.accentColor : Color(.secondarySystemBackground))
                VStack(spacing: 0) {
                    if let tag {
                        if geo.size.height >= 40 {
                            Text(tag).font(.system(size: 9)).opacity(0.6)
                        }
                        Text(action == .none ? "–" : action.shortLabel)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    } else if let symbol {
                        Image(systemName: symbol).font(.body.weight(.medium))
                    } else if let text {
                        Text(text).font(.body.weight(.medium))
                    }
                    if tag == nil, geo.size.height >= 40, action != .none {
                        Text(action.shortLabel)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(pressed ? Color.white : Color.primary)
                .padding(.horizontal, 2)
            }
        }
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
}
