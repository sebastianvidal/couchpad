import SwiftUI
import UIKit

/// The on-screen controller, in the key strip's place and style: a stick fixed on the left,
/// the face buttons in a diamond on the right, and seven programmable keys (the pad's
/// bumpers, triggers, stick click and menu, each showing its binding). Tall, the keys run
/// along the top above the stick and the diamond, like a hand-held console under its
/// screen; wide, everything sits in one short band: stick, keys, diamond.
/// Every control reports to `ControllerBridge`, so the profile that drives a physical pad
/// drives this one. The keys share the strip's multi-touch overlay, so a finger sliding
/// from one to the next releases the first and presses the next.
struct ControllerView: View {
    @ObservedObject var controller: ControllerBridge
    /// Height of one of the grid's rows (four tall, three wide); nil fills the parent.
    var rowHeight: CGFloat? = nil
    var wide = false
    @State private var keyFrames: [Int: CGRect] = [:]
    @State private var pressedCodes = Set<Int>()

    private let gap: CGFloat = 4
    /// The programmable row: labelled by what they do, tagged with the pad control they are.
    static let topRow: [(Control, String)] = [(.l1, "L1"), (.l2, "L2"), (.l3, "L3"), (.menu, "menu"), (.options, "opt"), (.r1, "R1"), (.r2, "R2")]
    /// Every key on the pad, with the synthetic code the touch overlay tracks it by.
    private static let padKeys: [(Control, Key)] = {
        let controls: [Control] = topRow.map(\.0) + [.y, .x, .b, .a]
        return controls.enumerated().map { ($1, Key(label: "", code: 1000 + $0)) }
    }()
    private static let keyByCode: [Int: Key] = Dictionary(uniqueKeysWithValues: padKeys.map { ($1.code, $1) })
    private static let controlByCode: [Int: Control] = Dictionary(uniqueKeysWithValues: padKeys.map { ($1.code, $0) })
    private static func code(_ control: Control) -> Int { padKeys.first { $0.0 == control }!.1.code }

    /// Fixed total height for a given row height, so the parent can lay out around it.
    static func height(rowHeight: CGFloat, wide: Bool) -> CGFloat {
        wide ? 3 * rowHeight + 2 * 4 : 4 * rowHeight + 3 * 4
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if wide { wideBody(geo.size) } else { tallBody(geo.size) }
            }
            // Pinned to the top under a picture; centred when it has a whole half to itself.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rowHeight == nil ? .center : .top)
            .coordinateSpace(name: "pad")
            .onPreferenceChange(KeyFramesKey.self) { keyFrames = $0 }
            .overlay(KeyTouchOverlay(frames: keyFrames, keys: ControllerView.keyByCode,
                                     onPress: { press($0, true) }, onRelease: { press($0, false) },
                                     onPressedChange: { pressedCodes = $0 }))
        }
        .frame(height: rowHeight.map { ControllerView.height(rowHeight: $0, wide: wide) })
    }

    /// Keys on top, stick and diamond under them.
    private func tallBody(_ size: CGSize) -> some View {
        let unit = (size.width - gap * 6) / 7
        // Keys stay key-shaped: however tall the column, a row is at most 1.2 keys high.
        let row = min(unit * 1.2, rowHeight ?? max(28, (size.height - gap * 3) / 4))
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                ForEach(ControllerView.topRow, id: \.0) { control, tag in
                    key(control, tag: tag).frame(width: unit, height: row)
                }
            }
            HStack(spacing: gap) {
                VirtualStick(controller: controller)
                    .frame(width: unit * 3 + gap * 2, height: row * 3 + gap * 2)
                diamond(unit: unit, row: row)
            }
            .frame(height: row * 3 + gap * 2)
        }
    }

    /// One band: stick, the seven keys, diamond.
    private func wideBody(_ size: CGSize) -> some View {
        let row = rowHeight ?? max(28, (size.height - gap * 2) / 3)
        let band = row * 3 + gap * 2
        let unit = (size.width - band * 2 - gap * 2 - gap * 6) / 7
        let keyHeight = min(band, unit * 1.2)
        return HStack(spacing: gap) {
            VirtualStick(controller: controller).frame(width: band, height: band)
            HStack(spacing: gap) {
                ForEach(ControllerView.topRow, id: \.0) { control, tag in
                    key(control, tag: tag).frame(width: unit, height: keyHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            diamond(unit: row, row: row).frame(width: band, height: band)
        }
        .frame(height: band)
    }

    /// Y and A sit 30% closer to the X–B row than a full row away: a tighter diamond
    /// the thumb covers without stretching, centred in its area.
    private func diamond(unit: CGFloat, row: CGFloat) -> some View {
        let lift = (row + gap) * 0.7
        return ZStack {
            key(.y, "Y").frame(width: unit, height: row).offset(y: -lift)
            key(.x, "X").frame(width: unit, height: row).offset(x: -(unit + gap))
            key(.b, "B").frame(width: unit, height: row).offset(x: unit + gap)
            key(.a, "A").frame(width: unit, height: row).offset(y: lift)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func key(_ control: Control, _ text: String? = nil, tag: String? = nil) -> some View {
        let code = ControllerView.code(control)
        return PadKey(action: controller.profile[control], text: text, tag: tag, pressed: pressedCodes.contains(code))
            .background(GeometryReader { geo in
                Color.clear.preference(key: KeyFramesKey.self, value: [code: geo.frame(in: .named("pad"))])
            })
            .accessibilityLabel("\(control.label): \(controller.profile[control].label)")
    }

    private func press(_ key: Key, _ down: Bool) {
        guard let control = ControllerView.controlByCode[key.code] else { return }
        if down { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        controller.setVirtual(control, pressed: down)
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

/// One pad key in the key strip's style. A face button shows its letter with the binding
/// under it; a programmable key shows the binding as its label with a small tag saying
/// which pad control it is. Dim when it does nothing.
private struct PadKey: View {
    let action: ControlAction
    var text: String? = nil
    var tag: String? = nil
    let pressed: Bool

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
                    } else if let text {
                        Text(text).font(.body.weight(.medium))
                        if geo.size.height >= 40, action != .none {
                            Text(action.shortLabel)
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .opacity(0.7)
                        }
                    }
                }
                .foregroundStyle(pressed ? Color.white : Color.primary)
                .padding(.horizontal, 2)
            }
        }
        .opacity(action == .none ? 0.45 : 1)
    }
}
