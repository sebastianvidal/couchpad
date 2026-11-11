import SwiftUI
import UIKit

/// The on-screen controller, in the key row's style: a stick fixed on the left,
/// the face buttons in a diamond on the right, and eight programmable keys (the pad's
/// bumpers, triggers, stick clicks and menu, each showing its binding). Tall, it is laid
/// out like a hand-held console under its screen: the strip's F bar and key row, when
/// shown (the bar's ⌘ button), at the top, then the shoulder keys (L2 and L1, R1 and R2)
/// in a row over the stick and the diamond, and L3, menu, opt and R3 grouped in the
/// middle under them. Wide, everything sits in one short band: stick, keys, diamond, with the strip
/// over the keys. As an overlay (sideways, `AppSettings.padOverlay`) the pad is drawn
/// translucent over the trackpad or picture instead (as solid as
/// `AppSettings.overlayOpacity`) and laid out like a controller: stick and diamond near its
/// bottom corners with the shoulder keys above them, the strip (when shown) on the bottom
/// line between them, and L3, menu, opt and R3 grouped over the strip.
/// Every control reports to `ControllerBridge`, so the profile that drives a physical pad
/// drives this one. The keys share the strip's multi-touch overlay, so a finger sliding
/// from one to the next releases the first and presses the next.
struct ControllerView: View {
    @ObservedObject var controller: ControllerBridge
    let client: Client
    @ObservedObject var state: InputState
    /// Tall: the key strip's row height (the pad's rows are sized to the strip's old height).
    /// Wide: the band's row height, a third of its height. Nil fills the parent: the keys
    /// stay key-shaped (at most 1.2 widths tall) and the room left over goes to the stick
    /// and to the air around it.
    var rowHeight: CGFloat? = nil
    var wide = false
    /// Over the trackpad or picture: fills its parent (the pane), ignores `rowHeight` and
    /// `wide`, and takes only the touches that land on a control (see `overlayBody`).
    var overlay = false
    /// How solid the overlay's resting keys are, 0 (labels only, faint) to 1 (solid keys):
    /// `AppSettings.overlayOpacity`, the labels a little stronger (`KeyButton.labelOpacity`).
    /// Only used with `overlay`.
    var overlayOpacity: Double = 0.5
    /// Only with `overlay`: the pad itself is off and only the strip is drawn, exactly where
    /// it sits with the pad, so turning the pad off or on moves nothing else.
    var padHidden = false
    /// The strip's F bar and key row (`AppSettings.showKeyRow`, the bar's ⌘ button).
    var showKeys = true
    @State private var pressedCodes = Set<Int>()
    @State private var showF = false
    /// The strip is a different view in the pad and while typing; this ties the two, so when
    /// the keyboard comes or goes the row slides to its new place instead of one copy fading
    /// out while another fades in. Upright the layout hands in its own (`stripSpace`), which
    /// its docked key row shares, so the row travels the same way when the pad comes or goes.
    @Namespace private var ownStripSpace
    var stripSpace: Namespace.ID? = nil
    private var strips: Namespace.ID { stripSpace ?? ownStripSpace }

    private static let gap: CGFloat = 4
    private var gap: CGFloat { Self.gap }
    /// The eight programmable keys, in the band's row order: labelled by what they do,
    /// tagged with the pad control they are.
    static let topRow: [(Control, String)] = [(.l1, "L1"), (.l2, "L2"), (.l3, "L3"), (.menu, "menu"), (.options, "opt"), (.r3, "R3"), (.r1, "R1"), (.r2, "R2")]
    /// Every key on the pad, with the synthetic code the touch overlay tracks it by.
    private static let padKeys: [(Control, Key)] = {
        let controls: [Control] = topRow.map(\.0) + [.y, .x, .b, .a]
        return controls.enumerated().map { ($1, Key(label: "", code: 1000 + $0)) }
    }()
    private static let keyByCode: [Int: Key] = Dictionary(uniqueKeysWithValues: padKeys.map { ($1.code, $1) })
    private static let controlByCode: [Int: Control] = Dictionary(uniqueKeysWithValues: padKeys.map { ($1.code, $0) })
    private static func code(_ control: Control) -> Int { padKeys.first { $0.0 == control }!.1.code }

    private static let barHeight: CGFloat = 28   // the strip's F bar
    private static let blockGap: CGFloat = 6     // between the strip and the pad, like every other block
    private var barHeight: CGFloat { Self.barHeight }
    private var blockGap: CGFloat { Self.blockGap }

    /// The tall layout's row height when it fills `size` (no `rowHeight`): key-shaped, about
    /// a seventh of the height (see `tallBody`).
    private static func fillingRow(in size: CGSize) -> CGFloat {
        let unit = (size.width - gap * 6) / 7
        let strip = barHeight + gap + blockGap   // the strip's bar and gaps; its row is a row
        return min(unit * 1.2, max(28, (size.height - strip - 2 * gap) / 6.75))
    }

    /// Where the controls under the strip begin in the tall pad filling `size`, the strip
    /// and the block gap above them (with F1–F12 closed); 0 with the key row off. Upright,
    /// the pad button's move opens the pad from there down (ContentView's `PadSlideEffect`).
    static func controlsTop(in size: CGSize, showKeys: Bool) -> CGFloat {
        showKeys ? barHeight + gap + fillingRow(in: size) + blockGap : 0
    }

    /// Tall: five rows (shoulders, three for the stick and the diamond, centre keys) and the
    /// air under them, plus the strip's F bar and key row when shown. Wide: one band, three
    /// rows tall. While the iOS keyboard is up the keyboard is the pad: only the strip row
    /// stays (nothing at all with the row off).
    private func blockHeight(rowHeight: CGFloat) -> CGFloat {
        let band = (3 * rowHeight + 2 * gap) * 1.1   // sideways: see wideBody
        let row = wide ? (band - barHeight - 2 * gap) / 2 : (3 * rowHeight + barHeight) / 4
        if state.keyboardShown { return showKeys ? barHeight + gap + (showF ? 2 * row + gap : row) : 0 }
        if wide { return band }
        return (showKeys ? barHeight + gap + row + blockGap : 0) + 5 * row + 4 * gap + tallFoot(row)
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
            // the strip upright and on the stick sideways, swallowing both). Read straight
            // into the overlay rather than through state: copied by `onPreferenceChange`, the
            // last value at launch upright with the key row on held only the strip's keys, so
            // no pad key took a touch until the next rotation.
            .overlayPreferenceValue(KeyFramesKey.self) { frames in
                KeyTouchOverlay(frames: frames.filter { ControllerView.keyByCode[$0.key] != nil }, keys: ControllerView.keyByCode,
                                onPress: { press($0, true) }, onRelease: { press($0, false) },
                                onPressedChange: { pressedCodes = $0 })
            }
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
            .matchedGeometryEffect(id: "strip", in: strips)
    }

    /// Laid out like a hand-held console's controls, top to bottom: the strip's F bar and
    /// key row when shown (the bar's ⌘ button), right under the picture or trackpad; the
    /// shoulder keys (L2 and L1 over the stick, R1 and R2 over the diamond, on one line, all
    /// four the same size); the stick and the diamond, a little further apart than they are
    /// from the sides; and the centre keys (L3, menu, opt and R3, grouped in the middle
    /// like select and start), a quarter row up from the bottom. All at one row height. Opening
    /// F1–F12 gives the two F rows the key row's and the shoulder keys' rows, so nothing
    /// else moves. Filling (upright, the pad's half of the window, or the flat half of a
    /// half-open Duo) the rows are key-shaped and about a seventh of the height each; the
    /// stick, the diamond and the air around them get the rest. With the key row off every
    /// key and the stick keep their size and the pad still fills its room: the centre keys
    /// stay where they are with it on, the shoulder keys sit three tenths of the height the
    /// strip leaves below the top, and the stick and the diamond are centred between the
    /// two. Given a row height, the stick and the diamond are three rows tall.
    private func tallBody(_ size: CGSize) -> some View {
        let unit = (size.width - gap * 6) / 7
        let fill = rowHeight == nil
        let strip = barHeight + gap + blockGap   // the strip's bar and gaps; its row is a row
        // The strip's, the shoulders' and the centre keys' row, the same with or without the
        // key row, so ⌘ changes no key's size.
        let row: CGFloat
        if let rowHeight {
            row = min(unit * 1.2, (3 * rowHeight + barHeight) / 4)
        } else {
            row = Self.fillingRow(in: size)
        }
        let foot = tallFoot(row)   // under the centre keys, off the pad's bottom edge
        // Between the shoulders and the centre keys, the stick and the diamond: three rows
        // tall given a row height, whatever the rows and the strip leave when filling. The
        // same with the key row off, so the stick neither grows nor shrinks when ⌘ is
        // tapped: the pad is then shorter than its room and sits in the middle of it.
        let above = row * 2 + gap * 2 + foot + strip + row
        let cluster = fill ? max(row * 3 + gap * 2, size.height - above) : row * 3 + gap * 2
        // Across, the stick is centred on the pad's left quarter line and the diamond on its
        // right one, so the two mirror each other about the middle, each at least `minAir`
        // off its side (with equal widths, the air between them is twice the air outside).
        let minAir: CGFloat = 10
        let half = size.width / 2
        let diamondWidth = unit * 3 + gap * 2
        let stick = fill
            ? max(0, min(cluster, size.width - diamondWidth - 4 * minAir, half - 2 * minAir))
            : unit * 3 + gap * 2
        // The face buttons as wide as the strip's keys, smaller only if the diamond would not
        // leave a little air above and below it in its room, or come nearer its side than
        // `minAir`.
        let face = max(0, min(unit, (cluster - gap * 1.2) / 2.4, (half - 2 * minAir - gap * 2) / 3))
        let diamondSeen = face * 3 + gap * 2   // the diamond's own width, X's edge to B's
        // Shoulder and centre keys: key-shaped, at most 1.7 rows wide, and each pair no
        // wider than the stick or the diamond under it.
        let wideKey = max(0, min(row * 1.7, (min(stick, diamondSeen) - gap) / 2, (size.width - gap * 3) / 4))
        // Filling with the key row off, the height the strip leaves: three tenths of it over
        // the shoulder keys, the rest shared above and below the stick and the diamond, so
        // the centre keys stay put and nothing looks cramped.
        let freed = fill && !showKeys ? strip + row : 0
        let spread = freed * 0.35   // added to the gap on each side of the stick and diamond
        return VStack(spacing: gap) {
            VStack(spacing: 0) {
                if showKeys {
                    // With F1–F12 open the F rows reach down to where the shoulder keys sat,
                    // which are a little further from the strip than the gap between rows.
                    KeyStripView(client: client, state: state, rowHeight: row, showFExternal: $showF)
                        .matchedGeometryEffect(id: "strip", in: strips)
                        .padding(.bottom, showF ? blockGap - gap : 0)
                }
                if !(showKeys && showF) {
                    // Each pair centred over its cluster: in the middle of its half.
                    HStack(spacing: 0) {
                        HStack(spacing: gap) {
                            key(.l2, tag: "L2").frame(width: wideKey, height: row)
                            key(.l1, tag: "L1").frame(width: wideKey, height: row)
                        }
                        .frame(width: half)
                        HStack(spacing: gap) {
                            key(.r1, tag: "R1").frame(width: wideKey, height: row)
                            key(.r2, tag: "R2").frame(width: wideKey, height: row)
                        }
                        .frame(width: half)
                    }
                    .padding(.top, showKeys ? blockGap : freed * 0.3)
                    .padding(.bottom, spread)
                }
            }
            HStack(spacing: 0) {
                VirtualStick(controller: controller)
                    .frame(width: stick, height: fill ? stick : cluster)
                    .frame(width: half)
                diamond(unit: unit, row: face).frame(width: half)
            }
            .frame(height: cluster)
            centreKeys(width: wideKey, height: row)
                .padding(.top, spread)
                .padding(.bottom, foot)
        }
    }

    /// The air under the tall pad's centre keys, for a row `row` high: they would otherwise
    /// sit on the pad's bottom edge, against the bar.
    private func tallFoot(_ row: CGFloat) -> CGFloat { row * 0.25 }

    /// One band: stick, a middle column (the eight programmable keys, with the strip's F
    /// bar and key row over them when shown, both rows the column's full width though the
    /// strip has seven columns; the F rows take both rows when opened), diamond.
    private func wideBody(_ size: CGSize) -> some View {
        // The stick's and the diamond's squares. Given a row height, three rows; filling,
        // as tall as the room allows but never so wide that the eight keys between them
        // drop under 44pt (the band used to be the room's full height, which on a wide,
        // short half pushed the diamond off the edge and crushed the middle to nothing).
        let band: CGFloat
        let faceUnit: CGFloat   // a face button's width
        let row: CGFloat        // and its height
        let edge: CGFloat       // air outside the stick and the diamond, off the band's ends
        let keysWidth = 8 * 44 + 7 * gap   // the eight keys, none under 44pt
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
        let unit = (middle - gap * 7) / 8   // a programmable key's width
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
                        .matchedGeometryEffect(id: "strip", in: strips)
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

    /// Over the trackpad or picture, like touch controls over a game, laid out like a
    /// controller: the stick in the bottom-leading corner, 32pt up from the pane's bottom,
    /// and the diamond in the bottom-trailing one, centred on the stick's height so the two
    /// share a centre line. The two mirror each other: their centres are as far from their
    /// sides, 40pt plus a quarter of both their widths (the diamond is the wider, so it
    /// reaches a little nearer its side and the middle than the stick). The shoulder keys
    /// sit in two rows level with each other, just above the stick's top: L2 outside and L1
    /// inside over the stick, R1 inside and R2 outside centred over the diamond, all four
    /// the same size (each pair as wide as the stick). On the pane's bottom line, centred on
    /// its middle with at least 16pt to the diamond, the strip (when the key row is on, ⌘):
    /// seven columns wide, at the keys' row height, as translucent as them. Right over it,
    /// centred on it, the centre keys: L3, menu, opt and R3 side by side, like select and
    /// start, each the size of a shoulder key (narrower only where four of those would be
    /// wider than the strip).
    /// Opening F1–F12 grows the strip to its two F rows and the centre keys ride up over
    /// them; with the key row off the centre keys sit on the bottom line themselves.
    /// Sized from the pane's width (the height only caps it, on a pane far shorter than a
    /// phone's), and the pane keeps its height whether or not the strip is shown, so ⌘ only
    /// adds or removes the strip: the stick a little bigger than the band's, the face
    /// buttons and the keys in proportion to it. Where the seven columns would come out
    /// under 36pt, the stick and the diamond first give back their move in from the sides
    /// (down to 24pt), then some of their size (down to 18% of the width).
    /// Only the controls take touches: no container here has a background, a content shape
    /// or a gesture, the strip's F bar is a button the size of the bar, and both touch
    /// overlays claim only their key frames, so every touch that misses a control (the gaps
    /// between keys included) reaches the trackpad underneath.
    /// The dark disc behind the stick keeps its ring, which is the disc's edge, visible over
    /// a bright picture; it follows `overlayOpacity` like the keys' fills and labels (0.2
    /// black at the default 0.5), while the ring and knob, faint already, stay as they are.
    private func overlayBody(_ size: CGSize) -> some View {
        let bottom: CGFloat = 16        // the strip (or the centre keys) off the pane's bottom
        let padBottom: CGFloat = 32     // the stick and the diamond off it
        let air: CGFloat = 16           // at least, between the keys and the stick or the diamond
        let shoulderGap: CGFloat = 10   // between a cluster and its shoulder keys
        let minUnit: CGFloat = 36       // the seven columns' narrowest
        // The room for the strip, centred on the pane, as wide as `edge` and `stick` leave
        // it. The diamond is 1.08 sticks and two gaps wide (see `face`); the two centres are
        // `edge` plus a quarter of both widths from their sides, so the diamond's inner edge,
        // the nearer of the two to the middle, is `edge` + 1.06 sticks + 3 gaps from its side.
        func room(edge: CGFloat, stick: CGFloat) -> CGFloat {
            size.width - edge * 2 - stick * 2.12 - gap * 3 - air * 2
        }
        let need = minUnit * 7 + gap * 6
        // About a tenth bigger than the band's stick, and no smaller than it.
        let fullStick = max(0, min(size.width * 0.20, size.height * 0.6))
        let leastStick = max(0, min(size.width * 0.18, size.height * 0.6))
        let edge = max(24, min(40, (room(edge: 0, stick: fullStick) - need) / 2))   // off the pane's sides
        let stick = max(leastStick, min(fullStick, (room(edge: edge, stick: 0) - need) / 2.12))
        let face = stick * 0.36         // a face button's diameter
        let diamondWidth = face * 3 + gap * 2
        let diamondHeight = face + 2 * diamondLift(face)
        let keyRow = stick * 0.28       // the keys' height
        // Key-shaped: as wide as the room allows, but never wider than 1.5 heights.
        let unit = max(0, min(keyRow * 1.5, (room(edge: edge, stick: stick) - gap * 6) / 7))
        let columns = unit * 7 + gap * 6
        // The stick's and the diamond's centres, the same distance from their sides, so the
        // two mirror each other about the pane's middle: the stick a quarter of the
        // difference in their widths further in than `edge` would put it, the diamond as
        // much further out.
        let inset = edge + (stick + diamondWidth) / 4
        let leading = inset - stick / 2                              // the stick's leading side
        let trailing = size.width - inset - diamondWidth / 2         // the diamond's leading side
        let middle = (size.width - columns) / 2                      // the strip's, centred
        let shoulder = max(0, (stick - gap) / 2)   // a shoulder key's width
        let diamondBottom = padBottom + (stick - diamondHeight) / 2   // centred on the stick
        let shoulderBottom = padBottom + stick + shoulderGap        // both rows, over the stick's top
        // The centre keys are the shoulder keys' size, unless four of them would be wider
        // than the strip.
        let centre = max(0, min(shoulder, (columns - gap * 3) / 4))
        // Each part is placed from the pane's bottom-leading corner. With the pad off
        // (`padHidden`) only the strip is drawn, where it sits with the pad.
        return ZStack(alignment: .bottomLeading) {
            if !padHidden {
                VirtualStick(controller: controller)
                    .frame(width: stick, height: stick)
                    .background(Circle().fill(Color.black.opacity(0.4 * overlayOpacity)).allowsHitTesting(false))
                    .padding(.leading, leading)
                    .padding(.bottom, padBottom)
                HStack(spacing: gap) {
                    key(.l2, tag: "L2").frame(width: shoulder, height: keyRow)
                    key(.l1, tag: "L1").frame(width: shoulder, height: keyRow)
                }
                .padding(.leading, leading)
                .padding(.bottom, shoulderBottom)
                diamond(unit: face, row: face)
                    .frame(width: diamondWidth, height: diamondHeight)
                    .padding(.leading, trailing)
                    .padding(.bottom, diamondBottom)
                HStack(spacing: gap) {
                    key(.r1, tag: "R1").frame(width: shoulder, height: keyRow)
                    key(.r2, tag: "R2").frame(width: shoulder, height: keyRow)
                }
                .padding(.leading, trailing + (diamondWidth - stick) / 2)
                .padding(.bottom, shoulderBottom)
            }
            VStack(spacing: gap) {
                if !padHidden {
                    centreKeys(width: centre, height: keyRow)
                }
                if showKeys {
                    KeyStripView(client: client, state: state, rowHeight: keyRow, showFExternal: $showF,
                                 overlayOpacity: overlayOpacity)
                        .frame(width: columns)
                }
            }
            // As wide as the strip whether or not it is shown, so the centre keys stay
            // centred over where it is.
            .frame(width: columns)
            .padding(.leading, middle)
            .padding(.bottom, bottom)
        }
        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
    }

    /// L3, menu, opt and R3 side by side, `gap` apart, each `width` by `height`: the centre
    /// group, like a hand-held's select and start, each stick's click on its own side.
    private func centreKeys(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: gap) {
            key(.l3, tag: "L3").frame(width: width, height: height)
            key(.menu, tag: "menu").frame(width: width, height: height)
            key(.options, tag: "opt").frame(width: width, height: height)
            key(.r3, tag: "R3").frame(width: width, height: height)
        }
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
        return PadKey(action: controller.profile[control], text: text, tag: tag, round: round,
                      overlayOpacity: overlay ? overlayOpacity : nil,
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
/// diagonals press two keys) is read from the knob's angle once it is off centre, and a
/// quarter of the ring centred on it is lit under the knob, from the resting knob's edge out
/// to the ring. Lines on the diagonals, over the same span, split the ring into the four
/// directions' quarters: a straight direction fills one, a diagonal straddles a line. The
/// ring is the frame's edge (over the picture, the edge of the dark disc behind it).
///
/// A touch works two ways. Put down and held still, it is a tap: wherever it lands, bar the
/// very centre, that direction is pressed, like a d-pad. Once the thumb moves it is a stick,
/// and the tap is over: the knob must leave a dead zone around the centre, as on a
/// controller, before anything is pressed. Lifting the thumb makes the next touch a tap again.
private struct VirtualStick: View {
    @ObservedObject var controller: ControllerBridge
    @State private var knob = CGPoint.zero   // offset from centre, clamped to the travel
    @State private var active = false
    @State private var moved = false         // the thumb has moved since it came down: a stick, not a tap
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
                    .frame(width: side, height: side)
                if let sector {
                    SectorWedge(sector: sector, inner: knobSize / 2)
                        .fill(Color.accentColor.opacity(0.28))
                        .frame(width: side - ring * 2, height: side - ring * 2)
                }
                Diagonals(inner: knobSize / 2)
                    .stroke(Color.primary.opacity(0.12), lineWidth: ring)
                    .frame(width: side - ring * 2, height: side - ring * 2)
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
                        if !moved, hypot(value.translation.width, value.translation.height) > Self.tapSlop { moved = true }
                        var dx = value.location.x - geo.size.width / 2
                        var dy = value.location.y - geo.size.height / 2
                        let distance = hypot(dx, dy)
                        if distance > travel { dx *= travel / distance; dy *= travel / distance }
                        knob = CGPoint(x: dx, y: dy)
                        if moved {
                            // A held direction lets go a little nearer the centre than it took
                            // hold, so a thumb resting on the edge of the dead zone doesn't flicker.
                            let dead = travel * (sector == nil ? Self.deadZone : Self.releaseZone)
                            sector = Self.sector(dx: dx, dy: dy, distance: distance, dead: dead)
                        } else {
                            // A tap goes by where it landed: a thumb that lands near the centre
                            // and pushes out presses nothing until it is past the dead zone.
                            let x = value.startLocation.x - geo.size.width / 2
                            let y = value.startLocation.y - geo.size.height / 2
                            sector = Self.sector(dx: x, dy: y, distance: hypot(x, y), dead: Self.tapDead)
                        }
                        press(Self.directions(sector))
                    }
                    .onEnded { _ in
                        sector = nil
                        press([])
                        active = false
                        moved = false
                        knob = .zero
                    }
            )
        }
        .accessibilityLabel("Movement stick")
    }

    /// A tap: only this close to the centre (points) presses nothing.
    private static let tapDead: CGFloat = 6
    /// How far (points) the thumb may wander and still be a tap.
    private static let tapSlop: CGFloat = 10
    /// The stick's dead zone, as a share of the knob's travel: a direction takes hold past
    /// `deadZone` and lets go inside `releaseZone`.
    private static let deadZone: CGFloat = 0.35
    private static let releaseZone: CGFloat = 0.28

    /// Eight 45° sectors, centred on the four directions and the diagonals between them,
    /// numbered counter-clockwise from right (0 right, 2 up, 4 left, 6 down). Within `dead`
    /// of the centre there is none (nil).
    private static func sector(dx: CGFloat, dy: CGFloat, distance: CGFloat, dead: CGFloat) -> Int? {
        guard distance > dead else { return nil }
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

    /// The 90° slice of the ring centred on a sector, from `inner` out to the edge of the
    /// frame: twice the sector's own 45°, so a straight direction lights the quarter between
    /// two diagonal lines. Sectors count counter-clockwise from right with y up; the path's y
    /// runs down, so the slice for sector n spans -45n ± 45° there. Relative arcs need no
    /// clockwise flag: out along the edge, back along `inner`, each joined by a line.
    private struct SectorWedge: Shape {
        let sector: Int
        let inner: CGFloat

        func path(in rect: CGRect) -> Path {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let start = -45 * Double(sector) - 45
            var path = Path()
            path.addRelativeArc(center: center, radius: min(rect.width, rect.height) / 2,
                                startAngle: .degrees(start), delta: .degrees(90))
            path.addRelativeArc(center: center, radius: inner,
                                startAngle: .degrees(start + 90), delta: .degrees(-90))
            path.closeSubpath()
            return path
        }
    }

    /// Lines at 45°, 135°, 225° and 315°, where one straight direction's quarter ends and the
    /// next begins: from `inner` (the resting knob's edge, so none show through it) out to
    /// the edge of the frame.
    private struct Diagonals: Shape {
        let inner: CGFloat

        func path(in rect: CGRect) -> Path {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let outer = min(rect.width, rect.height) / 2
            let unit = CGFloat(0.5).squareRoot()
            var path = Path()
            for (x, y) in [(unit, unit), (-unit, unit), (-unit, -unit), (unit, -unit)] {
                path.move(to: CGPoint(x: center.x + x * inner, y: center.y + y * inner))
                path.addLine(to: CGPoint(x: center.x + x * outer, y: center.y + y * outer))
            }
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
    /// Over a live picture (the overlay), how solid the resting key is (`AppSettings.overlayOpacity`,
    /// half by default): the fill, the background's colour, which pulls whatever is under
    /// the key towards the colour the label contrasts with, and the label with its soft
    /// shadow in that colour, a little stronger (`KeyButton.labelOpacity`), so it reads
    /// over bright and dark pictures alike. (The usual key
    /// colour at half strength vanished over the plain trackpad, which is that colour.) Nil
    /// is the solid docked look. Pressed is the full accent colour and a full label either way.
    var overlayOpacity: Double? = nil
    let pressed: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                let fill = pressed ? Color.accentColor : KeyButton.fill(overlayOpacity: overlayOpacity)
                if round {
                    Circle().fill(fill)
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill)
                }
                // The two lines read as one block: a Text's line box carries its font's descender
                // and line room, which opened a gap between a label and its sub-label, so the
                // stack overlaps them by about that much.
                VStack(spacing: tag != nil ? -2 : -3) {
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
                .labelShadow(overlayOpacity != nil && !pressed)
                .opacity(pressed ? 1 : KeyButton.labelOpacity(overlayOpacity: overlayOpacity))
                .padding(.horizontal, 2)
                // A face button's big letter over its small binding, centred as boxes, looks
                // high: the weight is in the letter. The pair sits 5% of the button lower.
                .offset(y: tag == nil && text != nil && geo.size.height >= 34 && action != .none ? geo.size.height * 0.05 : 0)
            }
        }
        .opacity(action == .none ? 0.45 : 1)
    }
}
