import SwiftUI

struct Key: Identifiable {
    let id = UUID()
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
            KeyButton(key: key, isHeld: state.heldModifiers.contains(key.code), windows: windows) {
                press(key)
            } onUp: {
                release(key)
            }
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

struct KeyButton: View {
    let key: Key
    let isHeld: Bool
    var windows = false
    let onDown: () -> Void
    let onUp: () -> Void
    @State private var pressed = false

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
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        onDown()
                    }
                }
                .onEnded { _ in
                    pressed = false
                    onUp()
                }
        )
    }
}
