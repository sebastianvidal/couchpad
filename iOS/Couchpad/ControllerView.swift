import SwiftUI
import UIKit

/// The on-screen controller, in the key row's style: a stick fixed on the left,
/// the face buttons in a diamond on the right, and seven programmable keys (the pad's
/// bumpers, triggers, stick click and menu, each showing its binding). Tall, the keys run
/// along the top above the stick and the diamond, like a hand-held console under its
/// screen; wide, everything sits in one short band: stick, keys, diamond. The strip's
/// F bar and key row, when shown (the bar's ⌘ button), are above the keys tall and over
/// them in the band wide.
/// Every control reports to `ControllerBridge`, so the profile that drives a physical pad
/// drives this one. The keys share the strip's multi-touch overlay, so a finger sliding
/// from one to the next releases the first and presses the next.
struct ControllerView: View {
    @ObservedObject var controller: ControllerBridge
    let client: Client
    @ObservedObject var state: InputState
    /// Tall: the key strip's row height (the pad below is sized to the strip's old height).
    /// Wide: the band's row height, a third of its height. Nil fills the parent: the keys
    /// stay key-shaped (at most 1.2 widths tall) and the room left over goes to the stick
    /// and to the air around it.
    var rowHeight: CGFloat? = nil
    var wide = false
    /// The strip's F bar and key row (`AppSettings.showKeyRow`, the bar's ⌘ button).
    var showKeys = true
    @State private var keyFrames: [Int: CGRect] = [:]
    @State private var pressedCodes = Set<Int>()
    @State private var showF = false

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

    private let barHeight: CGFloat = 28   // the strip's F bar
    private let blockGap: CGFloat = 6     // between the strip and the pad, like every other block

    /// Tall: a pad the height of the old three-row strip, plus the strip's F bar and key
    /// row when shown. Wide: one band, three rows tall. While the iOS keyboard is up the
    /// keyboard is the pad: only the strip row stays (nothing at all with the row off).
    private func blockHeight(rowHeight: CGFloat) -> CGFloat {
        let row = wide ? (3 * rowHeight + 2 * gap - barHeight - 2 * gap) / 2 : (3 * rowHeight + barHeight) / 4
        if state.keyboardShown { return showKeys ? barHeight + gap + (showF ? 2 * row + gap : row) : 0 }
        if wide { return 3 * rowHeight + 2 * gap }
        return (showKeys ? barHeight + gap + row + blockGap : 0) + 4 * row + 3 * gap
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if state.keyboardShown {
                    if showKeys { typingBody(geo.size) }
                } else if wide && (rowHeight != nil || geo.size.width > geo.size.height * 2.2) {
                    // Filling a room that is wide but not that wide (the flat half of an
                    // upright, half-open Duo is about 1.7:1), the band would be a strip across
                    // the middle with the rest empty: the tall layout fills it instead.
                    wideBody(geo.size)
                } else {
                    tallBody(geo.size)
                }
            }
            // Pinned to the top under a picture; centred when it has a whole half to itself.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rowHeight == nil ? .center : .top)
            .coordinateSpace(name: "pad")
            // The strip inside reports its keys through the same preference; its frames are in
            // its own space and must not become regions this overlay claims (they landed on
            // the strip upright and on the stick sideways, swallowing both).
            .onPreferenceChange(KeyFramesKey.self) { keyFrames = $0.filter { ControllerView.keyByCode[$0.key] != nil } }
            .overlay(KeyTouchOverlay(frames: keyFrames, keys: ControllerView.keyByCode,
                                     onPress: { press($0, true) }, onRelease: { press($0, false) },
                                     onPressedChange: { pressedCodes = $0 }))
        }
        .frame(height: rowHeight.map { blockHeight(rowHeight: $0) })
    }

    /// The iOS keyboard has taken the pad's place: just the strip row, full width, for
    /// shortcuts while typing and the button that puts the keyboard away again.
    private func typingBody(_ size: CGSize) -> some View {
        let unit = (size.width - gap * 6) / 7
        let row: CGFloat
        if let rowHeight {
            row = min(unit * 1.2, wide ? (3 * rowHeight - barHeight) / 2 : (3 * rowHeight + barHeight) / 4)
        } else {
            row = min(unit * 1.2, max(28, (size.height - barHeight - 2 * gap) / 2))
        }
        return KeyStripView(client: client, state: state, rowHeight: row, showFExternal: $showF)
    }

    /// The programmable keys, the stick and the diamond, with the strip's F bar and key
    /// row above them when shown, all at one row height. The pad is as tall as the
    /// three-row strip it replaced, so the picture above it keeps its share of the window.
    /// Opening F1–F12 swaps the key row and the programmable row for the two F rows.
    private func tallBody(_ size: CGSize) -> some View {
        let unit = (size.width - gap * 6) / 7
        let fill = rowHeight == nil
        let strip = barHeight + gap + blockGap   // the strip's bar and gaps; its row is a row
        // Given the strip's row height, the pad's four rows fill the strip's old height
        // (bar + three rows); filling a half, the rows share what there is, up to key shape.
        func rows(keys: Bool) -> (row: CGFloat, lower: CGFloat) {
            let row: CGFloat
            if let rowHeight {
                row = min(unit * 1.2, (3 * rowHeight + barHeight) / 4)
            } else {
                row = min(unit * 1.2, max(28, (size.height - (keys ? strip : 0) - 3 * gap) / (keys ? 5 : 4)))
            }
            // Under the keys, the stick and the diamond: three rows tall given a row height,
            // whatever the keys leave when filling.
            let above = (keys ? strip + row : 0) + row + gap
            return (row, fill ? max(row * 3 + gap * 2, size.height - above) : row * 3 + gap * 2)
        }
        let (row, lower) = rows(keys: showKeys)
        // Across, nothing depends on the key row: the stick is sized for the shorter room
        // it leaves (so it neither grows nor shrinks when ⌘ is tapped) and, with the
        // diamond, spaced evenly: the air left of the stick, between the two and right of
        // the diamond is the same, at least `minAir`.
        let minAir: CGFloat = 12
        let diamondWidth = unit * 3 + gap * 2
        let stick = fill
            ? max(0, min(lower, rows(keys: true).lower, size.width - diamondWidth - 3 * minAir))
            : unit * 3 + gap * 2
        let air = max(0, (size.width - stick - diamondWidth) / 3)
        return VStack(spacing: blockGap) {
            if showKeys {
                KeyStripView(client: client, state: state, rowHeight: row, showFExternal: $showF)
            }
            VStack(spacing: gap) {
                if !(showKeys && showF) {
                    HStack(spacing: gap) {
                        ForEach(ControllerView.topRow, id: \.0) { control, tag in
                            key(control, tag: tag).frame(width: unit, height: row)
                        }
                    }
                }
                HStack(spacing: air) {
                    VirtualStick(controller: controller)
                        .frame(width: stick, height: fill ? stick : lower)
                    diamond(unit: unit, row: row).frame(width: diamondWidth)
                }
                .padding(.horizontal, air)
                .frame(height: lower)
            }
        }
    }

    /// One band: stick, a middle column (the seven programmable keys, with the strip's F
    /// bar and key row over them when shown; the F rows take both rows when opened),
    /// diamond.
    private func wideBody(_ size: CGSize) -> some View {
        // The stick's and the diamond's squares. Given a row height, three rows; filling,
        // as tall as the room allows but never so wide that the seven keys between them
        // drop under 44pt (the band used to be the room's full height, which on a wide,
        // short half pushed the diamond off the edge and crushed the middle to nothing).
        let band: CGFloat
        let faceUnit: CGFloat   // a face button's width
        let row: CGFloat        // and its height
        if let rowHeight {
            row = rowHeight
            band = row * 3 + gap * 2
            faceUnit = row
        } else {
            let keysWidth = 7 * 44 + 6 * gap
            band = max(0, min(size.height, max(size.width * 0.22, min(size.width * 0.3, (size.width - gap * 2 - keysWidth) / 2))))
            faceUnit = (band - gap * 2) / 3
            row = min(faceUnit * 1.2, (band - gap * 1.2) / 2.2)
        }
        let middle = size.width - band * 2 - gap * 2
        let unit = (middle - gap * 6) / 7
        // With the strip: bar + gap + two key rows + gap fill the band exactly (filling, up
        // to key shape). Without it, the programmable keys stay key-shaped, centred in the band.
        let stripRow = (band - barHeight - 2 * gap) / 2
        let keyRow = showKeys ? (rowHeight == nil ? min(stripRow, unit * 1.2) : stripRow) : min(band, unit * 1.2)
        return HStack(spacing: gap) {
            VirtualStick(controller: controller).frame(width: band, height: band)
            VStack(spacing: gap) {
                if showKeys {
                    KeyStripView(client: client, state: state, rowHeight: keyRow, showFExternal: $showF)
                }
                if !(showKeys && showF) {
                    HStack(spacing: gap) {
                        ForEach(ControllerView.topRow, id: \.0) { control, tag in
                            key(control, tag: tag).frame(width: unit, height: keyRow)
                        }
                    }
                }
            }
            .frame(width: middle, height: band, alignment: showKeys && rowHeight != nil ? .top : .center)
            diamond(unit: faceUnit, row: row).frame(width: band, height: band)
        }
        .frame(height: band)
    }

    /// Y and A sit 40% closer to the X–B row than a full row away: a tighter diamond
    /// the thumb covers without stretching, centred in its area.
    private func diamond(unit: CGFloat, row: CGFloat) -> some View {
        let lift = (row + gap) * 0.6
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
                        if geo.size.height >= 34 {
                            Text(tag).font(.system(size: 9)).opacity(0.6)
                        }
                        Text(action == .none ? "–" : action.shortLabel)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    } else if let text {
                        Text(text).font(.body.weight(.medium))
                        if geo.size.height >= 34, action != .none {
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
