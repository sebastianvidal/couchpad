import SwiftUI

struct Key: Identifiable {
    let id = UUID()
    let label: String
    let code: Int            // macOS virtual keycode
    var width: CGFloat = 1
    var isModifier = false
    var symbol: String? = nil // SF Symbol instead of text
    var small = false
    var windowsLabel: String? = nil // text shown when the host is a PC; "" hides the key
}

/// Keys the iOS keyboard doesn't have. Plain keys send key-down on touch and key-up on
/// release, so holding works in games. Modifiers toggle and stay held until tapped again.
struct KeyStripView: View {
    @ObservedObject var client: Client
    @ObservedObject var state: InputState
    /// In a narrow column (landscape) rows are split in two so keys stay tappable.
    var compact = false
    @State private var showExtras = false

    private let strip: [Key] = [
        Key(label: "esc", code: 53, width: 1.2, small: true),
        Key(label: "", code: 48, symbol: "arrow.right.to.line"),
        Key(label: "", code: 59, isModifier: true, symbol: "control", windowsLabel: "Ctrl"),
        Key(label: "", code: 58, isModifier: true, symbol: "option", windowsLabel: "Alt"),
        Key(label: "", code: 55, isModifier: true, symbol: "command", windowsLabel: "Win"),
        Key(label: "", code: 56, isModifier: true, symbol: "shift"),
        Key(label: "", code: 123, symbol: "arrowtriangle.left.fill"),
        Key(label: "", code: 126, symbol: "arrowtriangle.up.fill"),
        Key(label: "", code: 125, symbol: "arrowtriangle.down.fill"),
        Key(label: "", code: 124, symbol: "arrowtriangle.right.fill"),
    ]

    private let fKeys: [Key] = [
        Key(label: "F1", code: 122, small: true), Key(label: "F2", code: 120, small: true), Key(label: "F3", code: 99, small: true), Key(label: "F4", code: 118, small: true), Key(label: "F5", code: 96, small: true), Key(label: "F6", code: 97, small: true), Key(label: "F7", code: 98, small: true), Key(label: "F8", code: 100, small: true), Key(label: "F9", code: 101, small: true), Key(label: "F10", code: 109, small: true), Key(label: "F11", code: 103, small: true), Key(label: "F12", code: 111, small: true),
    ]

    private let gameKeys: [Key] = [
        Key(label: "w", code: 13), Key(label: "a", code: 0), Key(label: "s", code: 1), Key(label: "d", code: 2),
        Key(label: "space", code: 49, width: 2, small: true), Key(label: "e", code: 14), Key(label: "r", code: 15),
        Key(label: "f", code: 3), Key(label: "q", code: 12), Key(label: "", code: 63, isModifier: true, symbol: "fn", small: true, windowsLabel: ""),
    ]

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    showExtras.toggle()
                } label: {
                    Label(showExtras ? "Hide extra keys" : "F-keys & hold keys", systemImage: showExtras ? "chevron.down" : "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
                ForEach(split(fKeys), id: \.first!.id) { row($0) }
                ForEach(split(gameKeys), id: \.first!.id) { row($0) }
            }
            ForEach(split(strip), id: \.first!.id) { row($0) }
        }
    }

    private func split(_ keys: [Key]) -> [[Key]] {
        guard compact, keys.count > 6 else { return [keys] }
        let half = (keys.count + 1) / 2
        return [Array(keys[..<half]), Array(keys[half...])]
    }

    private func row(_ allKeys: [Key]) -> some View {
        let keys = client.hostPlatform == .windows ? allKeys.filter { $0.windowsLabel != "" } : allKeys
        return GeometryReader { geo in
            let gap: CGFloat = 4
            let units = keys.reduce(0) { $0 + $1.width }
            let unit = (geo.size.width - gap * CGFloat(keys.count - 1)) / units
            HStack(spacing: gap) {
                ForEach(keys) { key in
                    KeyButton(key: key, isHeld: state.heldModifiers.contains(key.code),
                              windows: client.hostPlatform == .windows) {
                        press(key)
                    } onUp: {
                        release(key)
                    }
                    .frame(width: unit * key.width)
                }
            }
        }
        .frame(height: 40)
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
