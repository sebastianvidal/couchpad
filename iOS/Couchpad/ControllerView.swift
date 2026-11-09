import SwiftUI
import UIKit

/// The on-screen controller, in the key row's style: a stick fixed on the left,
/// the face buttons in a diamond on the right, and seven programmable keys (the pad's
/// bumpers, triggers, stick click and menu, each showing its binding). Tall, the keys run
/// along the top above the stick and the diamond, like a hand-held console under its
/// screen; wide, everything sits in one short band: stick, keys, diamond. The strip's
/// F bar and key row, when shown (the bar's ⌘ button), are above the keys tall and over
/// them in the band wide. As an overlay (sideways, `AppSettings.padOverlay`) the pad is
/// drawn translucent over the trackpad or picture instead: stick and diamond in its bottom
/// corners, the keys in a row between them, the key row docked under the pane by the parent.
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
    /// Over the trackpad or picture: fills its parent (the pane), ignores `rowHeight` and
    /// `wide`, and takes only the touches that land on a control (see `overlayBody`).
    var overlay = false
    /// The strip's F bar and key row (`AppSettings.showKeyRow`, the bar's ⌘ button).
    /// Off as an overlay: the parent docks the row under the pane instead.
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
        let band = (3 * rowHeight + 2 * gap) * 1.1   // sideways: see wideBody
        let row = wide ? (band - barHeight - 2 * gap) / 2 : (3 * rowHeight + barHeight) / 4
        if state.keyboardShown { return showKeys ? barHeight + gap + (showF ? 2 * row + gap : row) : 0 }
        if wide { return band }
        return (showKeys ? barHeight + gap + row + blockGap : 0) + 4 * row + 3 * gap
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if state.keyboardShown {
                    if showKeys { typingBody(geo.size) }
                } else if overlay {
                    overlayBody(geo.size)
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
        .frame(height: overlay ? nil : rowHeight.map { blockHeight(rowHeight: $0) })
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
        let edge: CGFloat       // air outside the stick and the diamond, off the band's ends
        let keysWidth = 7 * 44 + 6 * gap   // the seven keys, none under 44pt
        if let rowHeight {
            // The band is 10% taller than three rows so the stick (the band's full height)
            // grows with it; the face buttons are 10% bigger than a row plus 5pt (the
            // diamond is still well inside the band's height).
            band = (rowHeight * 3 + gap * 2) * 1.1
            row = rowHeight * 1.1 + 5
            faceUnit = row
            edge = 24
        } else {
            band = max(0, min(size.height, max(size.width * 0.22, min(size.width * 0.3, (size.width - gap * 2 - keysWidth) / 2))))
            faceUnit = (band - gap * 2) / 3
            row = min(faceUnit * 1.2, (band - gap * 1.2) / 2.2)
            edge = 0
        }
        let diamondWidth = rowHeight == nil ? band : faceUnit * 3 + gap * 2
        // Air between the stick and the keys and between the keys and the diamond. Given a
        // row height, 16pt, the keys giving up the width; on a phone too narrow for that it
        // shrinks (down to the keys' own gap) before the keys go under 44pt. Filling, the gap.
        let inner = rowHeight == nil
            ? gap
            : max(gap, min(16, (size.width - band - diamondWidth - edge * 2 - keysWidth) / 2))
        let middle = size.width - band - diamondWidth - inner * 2 - edge * 2
        let unit = (middle - gap * 6) / 7
        // With the strip: bar + gap + two key rows + gap fill the band exactly (filling, up
        // to key shape). Without it, the programmable keys stay key-shaped, centred in the band.
        let stripRow = (band - barHeight - 2 * gap) / 2
        // Given a row height, the programmable keys are the key row's height whether or not
        // the row is shown: tall slabs filling the band looked wrong.
        let keyRow = rowHeight == nil
            ? (showKeys ? min(stripRow, unit * 1.2) : min(band, unit * 1.2))
            : stripRow
        return HStack(spacing: inner) {
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
            diamond(unit: faceUnit, row: row).frame(width: diamondWidth, height: band)
        }
        .padding(.horizontal, edge)
        .frame(height: band)
    }

    /// Over the trackpad or picture, like touch controls over a game: the stick in the
    /// bottom-leading corner, the diamond in the bottom-trailing one, both 24pt in from the
    /// pane's sides and 16pt up from its bottom, and the seven programmable keys in one row
    /// centred between them along the same bottom line, slimmer than the band's.
    /// Sized from the pane's width (the height only caps it, on a pane far shorter than a
    /// phone's), so docking the key row under the pane (⌘) moves nothing: the stick a little
    /// bigger than the band's, the face buttons and the keys in proportion to it.
    /// Only the controls take touches: no container here has a background, a content shape
    /// or a gesture, and the touch overlay claims only the key frames, so every touch that
    /// misses a control reaches the trackpad underneath. The dark disc behind the stick
    /// keeps its ring visible over a bright picture.
    private func overlayBody(_ size: CGSize) -> some View {
        let edge: CGFloat = 24      // off the pane's sides
        let bottom: CGFloat = 16    // off its bottom
        let air: CGFloat = 16       // at least, between the keys and the stick or the diamond
        let stick = max(0, min(size.width * 0.18, size.height * 0.55))
        let face = stick * 0.36     // a face button's diameter
        let diamondWidth = face * 3 + gap * 2
        let keyRow = stick * 0.28   // the keys' height
        let room = size.width - edge * 2 - stick - diamondWidth - air * 2
        // Key-shaped: as wide as the room allows, but never wider than 1.5 heights.
        let unit = max(0, min(keyRow * 1.5, (room - gap * 6) / 7))
        return HStack(alignment: .bottom, spacing: 0) {
            VirtualStick(controller: controller)
                .frame(width: stick, height: stick)
                .background(Circle().fill(Color.black.opacity(0.2)).allowsHitTesting(false))
            Spacer(minLength: air)
            HStack(spacing: gap) {
                ForEach(ControllerView.topRow, id: \.0) { control, tag in
                    key(control, tag: tag).frame(width: unit, height: keyRow)
                }
            }
            Spacer(minLength: air)
            diamond(unit: face, row: face)
                .frame(width: diamondWidth, height: face + 2 * diamondLift(face))
        }
        .padding(.horizontal, edge)
        .padding(.bottom, bottom)
        .frame(width: size.width, height: size.height, alignment: .bottom)
    }

    /// How far Y and A sit above and below the X–B row, for a face button `d` across.
    private func diamondLift(_ d: CGFloat) -> CGFloat { (d + gap) * 0.6 }

    /// Y and A sit 40% closer to the X–B row than a full row away: a tighter diamond
    /// the thumb covers without stretching, centred in its area.
    /// The face buttons are round, the one place on the pad that is: a controller's buttons,
    /// not keys. Each is a circle as big as the key cell allows.
    private func diamond(unit: CGFloat, row: CGFloat) -> some View {
        let d = min(unit, row)
        let lift = diamondLift(d)
        return ZStack {
            key(.y, "Y", round: true).frame(width: d, height: d).offset(y: -lift)
            key(.x, "X", round: true).frame(width: d, height: d).offset(x: -(d + gap))
            key(.b, "B", round: true).frame(width: d, height: d).offset(x: d + gap)
            key(.a, "A", round: true).frame(width: d, height: d).offset(y: lift)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func key(_ control: Control, _ text: String? = nil, tag: String? = nil, round: Bool = false) -> some View {
        let code = ControllerView.code(control)
        return PadKey(action: controller.profile[control], text: text, tag: tag, round: round, translucent: overlay,
                      pressed: pressedCodes.contains(code))
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

/// A stick drawn as a ring with a knob that follows the thumb. The direction (8-way, so
/// diagonals press two keys) is read from the knob's angle once it is off centre, and the
/// 45° slice of the ring it falls in is lit under the knob.
private struct VirtualStick: View {
    @ObservedObject var controller: ControllerBridge
    @State private var knob = CGPoint.zero   // offset from centre, clamped to the travel
    @State private var active = false
    @State private var sector: Int?          // the lit slice; also decides what is held
    @State private var held = Set<Control>()
    private let haptic = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let knobSize = side * 0.42
            let travel = (side - knobSize) / 2
            let ring: CGFloat = 1.5
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: ring)
                    .frame(width: side * 0.86, height: side * 0.86)
                if let sector {
                    SectorWedge(sector: sector)
                        .fill(Color.accentColor.opacity(0.28))
                        .frame(width: side * 0.86 - ring * 2, height: side * 0.86 - ring * 2)
                }
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
                        sector = Self.sector(dx: dx, dy: dy, distance: distance)
                        press(Self.directions(sector))
                    }
                    .onEnded { _ in
                        sector = nil
                        press([])
                        active = false
                        knob = .zero
                    }
            )
        }
        .accessibilityLabel("Movement stick")
    }

    /// Eight 45° sectors, centred on the four directions and the diagonals between them,
    /// numbered counter-clockwise from right (0 right, 2 up, 4 left, 6 down). Only the very
    /// centre is dead (nil), so a tap anywhere on the stick presses that direction for as
    /// long as the finger is down, like a d-pad.
    private static func sector(dx: CGFloat, dy: CGFloat, distance: CGFloat) -> Int? {
        guard distance > 6 else { return nil }
        let degrees = (atan2(-dy, dx) * 180 / .pi + 360 + 22.5).truncatingRemainder(dividingBy: 360)
        return Int(degrees / 45)
    }

    private static func directions(_ sector: Int?) -> Set<Control> {
        guard let sector else { return [] }
        switch sector {
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

    /// The 45° pie slice of a sector, from the centre to the edge of the frame. Sectors count
    /// counter-clockwise from right with y up; the path's y runs down, so the slice for sector
    /// n spans -45n ± 22.5° there. A relative arc with a positive delta needs no clockwise flag.
    private struct SectorWedge: Shape {
        let sector: Int

        func path(in rect: CGRect) -> Path {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            var path = Path()
            path.move(to: center)
            path.addRelativeArc(center: center, radius: min(rect.width, rect.height) / 2,
                                startAngle: .degrees(-45 * Double(sector) - 22.5), delta: .degrees(45))
            path.closeSubpath()
            return path
        }
    }
}

/// One pad key in the key strip's style. A face button shows its letter with the binding
/// under it; a programmable key shows the binding as its label with a small tag saying
/// which pad control it is. Dim when it does nothing.
private struct PadKey: View {
    let action: ControlAction
    var text: String? = nil
    var tag: String? = nil
    var round = false
    /// Over a live picture (the overlay): the background's colour at half strength, which
    /// pulls whatever is under the key towards the colour the label contrasts with, plus a
    /// soft shadow in that colour, so labels read over bright and dark pictures alike.
    /// (The usual key colour at half strength vanished over the plain trackpad, which is
    /// that colour.) Pressed is the full accent colour either way.
    var translucent = false
    let pressed: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                let fill = pressed ? Color.accentColor
                    : translucent ? Color(.systemBackground).opacity(0.5) : Color(.secondarySystemBackground)
                if round {
                    Circle().fill(fill)
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill)
                }
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
                .shadow(color: translucent && !pressed ? Color(.systemBackground).opacity(0.9) : .clear, radius: 2)
                .padding(.horizontal, 2)
            }
        }
        .opacity(action == .none ? 0.45 : 1)
    }
}
