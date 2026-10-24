import SwiftUI

struct Key: Identifiable {
    let id = UUID()
    let label: String
    let code: Int            // macOS virtual keycode; -1 = blank spacer, -2 = "more keys" toggle
    var width: CGFloat = 1
    var isModifier = false
    var symbol: String? = nil // SF Symbol instead of text
    var small = false
    var windowsLabel: String? = nil // text shown when the host is a PC; "" blanks the key

    static let blank = Key(label: "", code: -1)
    static let more = Key(label: "", code: -2)
    var isBlank: Bool { code == -1 }
    var isToggle: Bool { code == -2 }
}

/// The keys the iOS keyboard doesn't have, laid out like the corner of a real keyboard:
/// esc top-left, delete top-right, modifiers along the bottom-left, a space bar, and the
/// arrows in an inverted T at bottom-right. Plain keys send key-down on touch and key-up on
/// release, so holding works in games. Modifiers toggle and stay held until tapped again.
struct KeyStripView: View {
    @ObservedObject var client: Client
    @ObservedObject var state: InputState
    /// Rows stretch to share whatever height is available (landscape).
    var fillsHeight = false
    @State private var showExtras = false

    private static let columns: CGFloat = 7

    private let baseRows: [[Key]] = [
        [Key(label: "esc", code: 53, small: true),
         Key(label: "", code: 48, symbol: "arrow.right.to.line"),
         Key(label: "", code: 63, isModifier: true, symbol: "fn", small: true, windowsLabel: ""),
         .more,
         .blank,
         Key(label: "", code: 51, width: 2, symbol: "delete.left")],
        [Key(label: "", code: 56, isModifier: true, symbol: "shift"),
         Key(label: "", code: 59, isModifier: true, symbol: "control", windowsLabel: "Ctrl"),
         Key(label: "", code: 58, isModifier: true, symbol: "option", windowsLabel: "Alt"),
         Key(label: "", code: 55, isModifier: true, symbol: "command", windowsLabel: "Win"),
         .blank,
         Key(label: "", code: 126, symbol: "arrowtriangle.up.fill"),
         .blank],
        [Key(label: "space", code: 49, width: 4, small: true),
         Key(label: "", code: 123, symbol: "arrowtriangle.left.fill"),
         Key(label: "", code: 125, symbol: "arrowtriangle.down.fill"),
         Key(label: "", code: 124, symbol: "arrowtriangle.right.fill")],
    ]

    private let extraRows: [[Key]] = [
        [Key(label: "F1", code: 122, small: true), Key(label: "F2", code: 120, small: true), Key(label: "F3", code: 99, small: true), Key(label: "F4", code: 118, small: true), Key(label: "F5", code: 96, small: true), Key(label: "F6", code: 97, small: true), Key(label: "F7", code: 98, small: true)],
        [Key(label: "F8", code: 100, small: true), Key(label: "F9", code: 101, small: true), Key(label: "F10", code: 109, small: true), Key(label: "F11", code: 103, small: true), Key(label: "F12", code: 111, small: true), Key(label: "`", code: 50), Key(label: "⇪", code: 57)],
        [Key(label: "q", code: 12), Key(label: "w", code: 13), Key(label: "e", code: 14), Key(label: "r", code: 15), Key(label: "f", code: 3), Key(label: "-", code: 27), Key(label: "=", code: 24)],
        [Key(label: "a", code: 0), Key(label: "s", code: 1), Key(label: "d", code: 2), Key(label: "[", code: 33), Key(label: "]", code: 30), Key(label: ";", code: 41), Key(label: "'", code: 39)],
    ]

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                if !state.heldModifiers.isEmpty {
                    Button("Release modifiers") { releaseModifiers() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.orange)
                }
                Spacer()
                Button {
                    state.keyboardShown.toggle()
                } label: {
                    Image(systemName: state.keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if showExtras {
                ForEach(extraRows.indices, id: \.self) { row(extraRows[$0]) }
            }
            ForEach(baseRows.indices, id: \.self) { row(baseRows[$0]) }
        }
    }

    private func row(_ keys: [Key]) -> some View {
        GeometryReader { geo in
            let gap: CGFloat = 4
            let unit = (geo.size.width - gap * (KeyStripView.columns - 1)) / KeyStripView.columns
            HStack(spacing: gap) {
                ForEach(keys) { key in
                    keyView(key)
                        .frame(width: unit * key.width + gap * (key.width - 1), height: geo.size.height)
                }
            }
        }
        .frame(minHeight: 36, maxHeight: fillsHeight ? .infinity : 42)
    }

    @ViewBuilder
    private func keyView(_ key: Key) -> some View {
        let windows = client.hostPlatform == .windows
        if key.isBlank || (windows && key.windowsLabel == "") {
            Color.clear
        } else if key.isToggle {
            Button {
                showExtras.toggle()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(showExtras ? Color.accentColor.opacity(0.35) : Color(.secondarySystemBackground))
                    Image(systemName: showExtras ? "chevron.down" : "ellipsis")
                        .foregroundStyle(Color.primary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showExtras ? "Hide extra keys" : "More keys")
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
