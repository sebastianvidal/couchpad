import SwiftUI
import UIKit
import Combine

/// Modifier keys toggled on in the key strip. While any is held, typed characters
/// are sent as real keycodes so shortcuts like ⌘C reach the Mac.
final class InputState: ObservableObject {
    @Published var heldModifiers = Set<Int>()
    @Published var keyboardShown = true
    /// True while a sheet (setup, settings, scanner) is presented: the keyboard stays down.
    @Published var suspended = false
}

/// Invisible view that owns the iOS keyboard and forwards what is typed.
struct KeyInputView: UIViewRepresentable {
    let client: Client
    @ObservedObject var state: InputState

    func makeUIView(context: Context) -> KeyInputUIView {
        let view = KeyInputUIView()
        view.client = client
        view.inputState = state
        return view
    }

    func updateUIView(_ uiView: KeyInputUIView, context: Context) {
        let wanted = state.keyboardShown && !state.suspended
        DispatchQueue.main.async {
            if wanted {
                if !uiView.isFirstResponder { _ = uiView.becomeFirstResponder() }
            } else if uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }
}

/// A real text field (so iOS reliably honors "no autocorrect, no predictions"). Keystrokes
/// arrive through the delegate, are forwarded, and are never stored: the field only ever
/// holds one zero-width sentinel so that backspace is still reported.
final class KeyInputUIView: UITextField, UITextFieldDelegate {
    weak var client: Client?
    weak var inputState: InputState?

    private static let sentinel = "\u{200B}"
    /// The field that last took the keyboard. Each layout's bar has its own field, and a
    /// layout change hands the keyboard from one to the next.
    private static weak var owner: KeyInputUIView?
    /// Whether one of these fields has the keyboard, i.e. whether a keyboard going away
    /// was ours being dismissed by iOS rather than handed over.
    static var ownsKeyboard: Bool { owner?.isFirstResponder == true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { KeyInputUIView.owner = self }
        return became
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        if #available(iOS 17.0, *) { inlinePredictionType = .no }
        textContentType = nil
        keyboardType = .asciiCapable
        keyboardAppearance = .dark
        returnKeyType = .default
        tintColor = .clear
        textColor = .clear
        backgroundColor = .clear
        text = KeyInputUIView.sentinel
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, inputState?.keyboardShown != false, inputState?.suspended != true else { return }
        DispatchQueue.main.async {
            // Asked again: the keyboard may have been put away in the meantime (a layout
            // change that also hides it), and a field taking it now would leave it up
            // with nothing on screen expecting it.
            guard self.window != nil, self.inputState?.keyboardShown == true, self.inputState?.suspended != true else { return }
            _ = self.becomeFirstResponder()
        }
    }

    // No caret, no selection handles, no edit menu.
    override func caretRect(for position: UITextPosition) -> CGRect { .zero }
    override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if string.isEmpty {
            tap(51) // backspace
        } else {
            forward(string)
        }
        if text != KeyInputUIView.sentinel { text = KeyInputUIView.sentinel }
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        tap(36)
        return false
    }

    private func forward(_ string: String) {
        if string == "\n" {
            tap(36)
            return
        }
        if let inputState, !inputState.heldModifiers.isEmpty {
            for ch in string {
                if let code = Keycodes.code(for: ch) { tap(code) }
            }
            return
        }
        client?.send("t \(string)")
    }

    private func tap(_ code: Int) {
        client?.send("k \(code) 1")
        client?.send("k \(code) 0")
    }
}

enum Keycodes {
    private static let map: [Character: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]

    static func code(for ch: Character) -> Int? {
        map[Character(ch.lowercased())]
    }
}
