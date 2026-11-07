import SwiftUI

struct Key: Identifiable {
    /// Keycodes are unique across the strip, and stable across view rebuilds (a UUID would
    /// change every time SwiftUI remade the strip).
    var id: Int { code }
    let label: String
    let code: Int            // macOS virtual keycode
    var width: CGFloat = 1   // in grid columns
    var isModifier = false
    var symbol: String? = nil // SF Symbol instead of text
    var small = false
    var windowsLabel: String? = nil // text shown when the host is a PC; "" blanks the key
}

/// The keys the iOS keyboard doesn't have, laid out like the corner of a real keyboard, in
/// seven columns with no empty cells:
///
///     esc  tab  fn   '   ⌫ ⌫ ⌫
///      ⇧    ⌃    ⌥   ⌘   ←  ↑  →
///        space (4)       ←  ↓  →      (← and → are one tall key each)
///
/// Above it, a slim "F1–F12" bar expands two rows of function keys. Row heights are fixed, so
/// the block never changes size when the iOS keyboard appears. Plain keys send key-down on
/// touch and key-up on release, so holding works in games. Modifiers toggle and stay held.
struct KeyStripView: View {
    @ObservedObject var client: Client
    @ObservedObject var state: InputState
    var rowHeight: CGFloat = 42
    /// When the iOS keyboard is out there is no room to grow: the F-bar then swaps the
    /// three main rows for the two F-key rows in the same space instead of adding rows.
    var replacesRowsWhenExpanded = false
    @State private var showF = false
    /// Where each visible key is, in the strip's coordinate space, for the touch overlay.
    @State private var keyFrames: [Int: CGRect] = [:]
    /// Keys currently under a finger (modifiers show as held instead).
    @State private var pressedKeys = Set<Int>()

    private let gap: CGFloat = 4
    private let columns: CGFloat = 7
    private let barHeight: CGFloat = 28

    private let topRow: [Key] = [
        Key(label: "esc", code: 53, small: true),
        Key(label: "", code: 48, symbol: "arrow.right.to.line"),
        Key(label: "", code: 63, isModifier: true, symbol: "fn", small: true, windowsLabel: ""),
        Key(label: "'", code: 39),
        Key(label: "", code: 51, width: 3, symbol: "delete.left"),
    ]
    private let modifierRow: [Key] = [
        Key(label: "", code: 56, isModifier: true, symbol: "shift"),
        Key(label: "", code: 59, isModifier: true, symbol: "control", windowsLabel: "Ctrl"),
        Key(label: "", code: 58, isModifier: true, symbol: "option", windowsLabel: "Alt"),
        Key(label: "", code: 55, isModifier: true, symbol: "command", windowsLabel: "Win"),
    ]
    private let spaceRow: [Key] = [Key(label: "space", code: 49, width: 4, small: true)]
    private let left = Key(label: "", code: 123, symbol: "arrowtriangle.left.fill")
    private let right = Key(label: "", code: 124, symbol: "arrowtriangle.right.fill")
    private let up = Key(label: "", code: 126, symbol: "arrowtriangle.up.fill")
    private let down = Key(label: "", code: 125, symbol: "arrowtriangle.down.fill")
    private let fRows: [[Key]] = [
        [Key(label: "F1", code: 122, small: true), Key(label: "F2", code: 120, small: true), Key(label: "F3", code: 99, small: true), Key(label: "F4", code: 118, small: true), Key(label: "F5", code: 96, small: true), Key(label: "F6", code: 97, small: true), Key(label: "F7", code: 98, small: true)],
        [Key(label: "F8", code: 100, small: true), Key(label: "F9", code: 101, small: true), Key(label: "F10", code: 109, small: true), Key(label: "F11", code: 103, small: true), Key(label: "F12", code: 111, small: true), Key(label: "`", code: 50), Key(label: "⇪", code: 57)],
    ]

    /// Fixed total height, so the parent can lay out around a block that never changes.
    var height: CGFloat {
        let rows: CGFloat = (showF && !replacesRowsWhenExpanded) ? 5 : 3
        return barHeight + gap + rows * rowHeight + (rows - 1) * gap
    }

    /// Two F rows standing in for three main rows share their exact height.
    private var swappedRowHeight: CGFloat { (3 * rowHeight + 2 * gap - gap) / 2 }

    private var allKeys: [Int: Key] {
        var keys: [Int: Key] = [:]
        for key in topRow + modifierRow + spaceRow + [left, right, up, down] + fRows.flatMap({ $0 }) { keys[key.code] = key }
        return keys
    }

    var body: some View {
        GeometryReader { geo in
            let unit = (geo.size.width - gap * (columns - 1)) / columns
            VStack(spacing: gap) {
                fBar
                if showF && replacesRowsWhenExpanded {
                    ForEach(fRows.indices, id: \.self) { row(fRows[$0], unit: unit, height: swappedRowHeight) }
                } else {
                if showF {
                    ForEach(fRows.indices, id: \.self) { row(fRows[$0], unit: unit) }
                }
                row(topRow, unit: unit)
                HStack(spacing: gap) {
                    VStack(spacing: gap) {
                        row(modifierRow, unit: unit)
                        row(spaceRow, unit: unit)
                    }
                    .frame(width: unit * 4 + gap * 3)
                    HStack(spacing: gap) {
                        keyView(left).frame(width: unit, height: rowHeight * 2 + gap)
                        VStack(spacing: gap) {
                            keyView(up).frame(width: unit, height: rowHeight)
                            keyView(down).frame(width: unit, height: rowHeight)
                        }
                        keyView(right).frame(width: unit, height: rowHeight * 2 + gap)
                    }
                }
                }
            }
            .coordinateSpace(name: "keys")
            .onPreferenceChange(KeyFramesKey.self) { keyFrames = $0 }
            // One multi-touch surface over all the keys: a finger that slides from one key
            // to the next releases the first and presses the next, like rolling across a
            // real keyboard. Touches outside the keys fall through to the bar's buttons.
            .overlay(KeyTouchOverlay(frames: keyFrames, keys: allKeys, onPress: press, onRelease: release,
                                     onPressedChange: { pressedKeys = $0 }))
        }
        .frame(height: height)
    }

    private var fBar: some View {
        HStack(spacing: gap) {
            Button {
                showF.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showF ? "chevron.down" : "chevron.up").font(.caption2)
                    Text("F1–F12").font(.caption)
                }
                .frame(maxWidth: .infinity)
                .frame(height: barHeight)
                .background(showF ? Color.accentColor.opacity(0.35) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .foregroundStyle(Color.primary)
            }
            .buttonStyle(.plain)
            if !state.heldModifiers.isEmpty {
                Button {
                    releaseModifiers()
                } label: {
                    Text("Release")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .frame(height: barHeight)
                        .background(Color.orange.opacity(0.35), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
            }
            Button {
                state.keyboardShown.toggle()
            } label: {
                Image(systemName: state.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                    .padding(.horizontal, 12)
                    .frame(height: barHeight)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(Color.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.keyboardShown ? "Hide keyboard" : "Show keyboard")
        }
    }

    private func row(_ keys: [Key], unit: CGFloat, height: CGFloat? = nil) -> some View {
        HStack(spacing: gap) {
            ForEach(keys) { key in
                keyView(key).frame(width: unit * key.width + gap * (key.width - 1), height: height ?? rowHeight)
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: Key) -> some View {
        let windows = client.hostPlatform == .windows
        if windows && key.windowsLabel == "" {
            Color.clear
        } else {
            KeyButton(key: key, pressed: pressedKeys.contains(key.code), isHeld: state.heldModifiers.contains(key.code), windows: windows)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: KeyFramesKey.self, value: [key.code: geo.frame(in: .named("keys"))])
                })
        }
    }

    private func press(_ key: Key) {
        if key.isModifier {
            if state.heldModifiers.contains(key.code) {
                state.heldModifiers.remove(key.code)
                client.send("k \(key.code) 0")
            } else {
                state.heldModifiers.insert(key.code)
                client.send("k \(key.code) 1")
            }
        } else {
            client.send("k \(key.code) 1")
        }
    }

    private func release(_ key: Key) {
        guard !key.isModifier else { return }
        client.send("k \(key.code) 0")
    }

    private func releaseModifiers() {
        for code in state.heldModifiers { client.send("k \(code) 0") }
        state.heldModifiers.removeAll()
    }
}

struct KeyFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct KeyTouchOverlay: UIViewRepresentable {
    var frames: [Int: CGRect]
    var keys: [Int: Key]
    var onPress: (Key) -> Void
    var onRelease: (Key) -> Void
    var onPressedChange: (Set<Int>) -> Void

    func makeUIView(context: Context) -> KeyTouchUIView {
        let view = KeyTouchUIView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: KeyTouchUIView, context: Context) {
        uiView.frames = frames
        uiView.keys = keys
        uiView.onPress = onPress
        uiView.onRelease = onRelease
        uiView.onPressedChange = onPressedChange
    }
}

final class KeyTouchUIView: UIView {
    var frames: [Int: CGRect] = [:]
    var keys: [Int: Key] = [:]
    var onPress: ((Key) -> Void)?
    var onRelease: ((Key) -> Void)?
    var onPressedChange: ((Set<Int>) -> Void)?
    /// The non-modifier key each finger is holding down, if any.
    private var held: [ObjectIdentifier: Int] = [:]
    private var pressed = Set<Int>()

    /// Only the keys are ours; anything else (the F-bar buttons) is for the views below.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        frames.values.contains { $0.contains(point) }
    }

    private func key(at point: CGPoint) -> Key? {
        guard let code = frames.first(where: { $0.value.contains(point) })?.key else { return nil }
        return keys[code]
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let key = key(at: touch.location(in: self)) else { continue }
            onPress?(key)   // modifiers toggle here and only here
            if !key.isModifier {
                held[ObjectIdentifier(touch)] = key.code
                pressed.insert(key.code)
            }
        }
        onPressedChange?(pressed)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var changed = false
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let under = key(at: touch.location(in: self))
            guard under?.code != held[id] else { continue }
            if let code = held[id], let key = keys[code] {
                onRelease?(key)
                pressed.remove(code)
                held[id] = nil
                changed = true
            }
            // Sliding onto a modifier does nothing: toggling one by accident is worse than missing it.
            if let under, !under.isModifier {
                onPress?(under)
                held[id] = under.code
                pressed.insert(under.code)
                changed = true
            }
        }
        if changed { onPressedChange?(pressed) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if let code = held[id], let key = keys[code] {
                onRelease?(key)
                pressed.remove(code)
                held[id] = nil
            }
        }
        onPressedChange?(pressed)
    }
}

struct KeyButton: View {
    let key: Key
    let pressed: Bool
    let isHeld: Bool
    var windows = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(pressed || isHeld ? Color.accentColor : Color(.secondarySystemBackground))
            Group {
                if windows, let text = key.windowsLabel, !text.isEmpty {
                    Text(text)
                } else if let symbol = key.symbol {
                    Image(systemName: symbol)
                } else {
                    Text(key.label)
                }
            }
            .font(key.small || (windows && key.windowsLabel != nil) ? .caption : .body)
            .fontWeight(.medium)
            .foregroundStyle(pressed || isHeld ? Color.white : Color.primary)
        }
    }
}
