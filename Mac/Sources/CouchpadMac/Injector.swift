import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Turns protocol lines into CGEvents. Line format (space separated):
///   m dx dy        move pointer by delta (also carried as raw mouse delta for games)
///   M fx fy        move pointer to a point on the streamed display (fractions 0…1)
///   s dx dy        scroll by pixels
///   b l|r 1|0      mouse button down/up
///   c l|r          click
///   k code 1|0     key down/up (macOS virtual keycode)
///   t text         type text (unicode, rest of line)
///   r              release everything held
final class Injector {
    static let shared = Injector()

    private let source = CGEventSource(stateID: .combinedSessionState)
    private var modifiers: CGEventFlags = []
    private var heldKeys = Set<CGKeyCode>()
    private var leftDown = false
    private var rightDown = false
    private var lastClickTime: TimeInterval = 0
    private var clickCount: Int64 = 0
    private var cachedBounds = CGRect.zero
    private var boundsCachedAt: TimeInterval = 0
    private var lastUserActivity: TimeInterval = 0
    private var userActivityID: IOPMAssertionID = 0

    func handle(_ line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let command = parts.first else { return }
        declareUserActivity()
        switch command {
        case "m":
            guard parts.count >= 3, let dx = Int(parts[1]), let dy = Int(parts[2]) else { return }
            move(dx: dx, dy: dy)
        case "M":
            guard parts.count >= 3, let fx = Double(parts[1]), let fy = Double(parts[2]) else { return }
            moveAbsolute(fx: fx, fy: fy)
        case "s":
            guard parts.count >= 3, let dx = Int32(parts[1]), let dy = Int32(parts[2]) else { return }
            scroll(dx: dx, dy: dy)
        case "b":
            guard parts.count >= 3 else { return }
            button(parts[1] == "r" ? .right : .left, down: parts[2] == "1")
        case "c":
            guard parts.count >= 2 else { return }
            let b: CGMouseButton = parts[1] == "r" ? .right : .left
            button(b, down: true)
            button(b, down: false)
        case "k":
            guard parts.count >= 3, let code = UInt16(parts[1]) else { return }
            key(CGKeyCode(code), down: parts[2] == "1")
        case "t":
            type(String(line.dropFirst(2)))
        case "g":
            guard parts.count >= 2 else { return }
            gesture(String(parts[1]))
        case "r":
            releaseAll()
        default:
            break
        }
    }

    /// Synthetic CGEvents don't count as user activity, so a sleeping display stays dark
    /// and the idle timer keeps running while the phone is in use. Tell power management
    /// a user is here: this wakes the display if it's asleep and resets the idle timer.
    /// Throttled; the declaration is good for a few seconds anyway.
    private func declareUserActivity() {
        let now = Date().timeIntervalSince1970
        if now - lastUserActivity < 2 { return }
        lastUserActivity = now
        IOPMAssertionDeclareUserActivity("Couchpad input" as CFString, kIOPMUserActiveLocal, &userActivityID)
    }

    /// Three-finger swipes from the phone, as the keyboard shortcuts for the same actions
    /// (macOS has no public API for synthetic trackpad gestures):
    /// up = Mission Control, down = App Exposé, left/right = previous/next Space.
    private func gesture(_ direction: String) {
        let arrow: CGKeyCode
        switch direction {
        case "up": arrow = 126
        case "down": arrow = 125
        case "left": arrow = 123
        case "right": arrow = 124
        default: return
        }
        let saved = modifiers
        key(59, down: true)        // control
        key(arrow, down: true)
        key(arrow, down: false)
        key(59, down: false)
        modifiers = saved
    }

    // MARK: Mouse

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func screenBounds() -> CGRect {
        let now = Date().timeIntervalSince1970
        if now - boundsCachedAt < 5 { return cachedBounds }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        var rect = CGRect.null
        for id in ids.prefix(Int(count)) { rect = rect.union(CGDisplayBounds(id)) }
        cachedBounds = rect.isNull ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : rect
        boundsCachedAt = now
        return cachedBounds
    }

    private func move(dx: Int, dy: Int) {
        var p = currentLocation()
        let b = screenBounds()
        p.x = min(max(p.x + CGFloat(dx), b.minX), b.maxX - 1)
        p.y = min(max(p.y + CGFloat(dy), b.minY), b.maxY - 1)
        let type: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                              mouseButton: rightDown && !leftDown ? .right : .left) else { return }
        // Games that read raw mouse input look at the deltas, not the cursor position.
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        e.flags = modifiers
        e.post(tap: .cghidEventTap)
    }

    /// The phone tapped a spot on the picture: put the pointer there. Deltas are carried too,
    /// so a drag across the picture still reads as mouse movement to a game.
    private func moveAbsolute(fx: Double, fy: Double) {
        let b = ScreenStreamer.shared.displayBounds
        let target = CGPoint(x: b.minX + min(max(fx, 0), 1) * b.width, y: b.minY + min(max(fy, 0), 1) * b.height)
        let from = currentLocation()
        let p = CGPoint(x: min(target.x, b.maxX - 1), y: min(target.y, b.maxY - 1))
        let type: CGEventType = leftDown ? .leftMouseDragged : (rightDown ? .rightMouseDragged : .mouseMoved)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                              mouseButton: rightDown && !leftDown ? .right : .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - from.x).rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - from.y).rounded()))
        e.flags = modifiers
        e.post(tap: .cghidEventTap)
    }

    private func button(_ button: CGMouseButton, down: Bool) {
        let type: CGEventType
        switch (button, down) {
        case (.right, true): type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (_, true): type = .leftMouseDown
        case (_, false): type = .leftMouseUp
        }
        if down {
            let now = Date().timeIntervalSince1970
            clickCount = (now - lastClickTime < 0.35) ? clickCount + 1 : 1
            lastClickTime = now
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: currentLocation(),
                              mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickCount)
        e.flags = modifiers
        e.post(tap: .cghidEventTap)
        if button == .right { rightDown = down } else { leftDown = down }
    }

    private func scroll(dx: Int32, dy: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    private func modifierFlag(for code: CGKeyCode) -> CGEventFlags? {
        switch code {
        case 56, 60: return .maskShift
        case 59, 62: return .maskControl
        case 58, 61: return .maskAlternate
        case 55, 54: return .maskCommand
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    private func key(_ code: CGKeyCode, down: Bool) {
        if let flag = modifierFlag(for: code) {
            if down { modifiers.insert(flag) } else { modifiers.remove(flag) }
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        var flags = modifiers
        if (123...126).contains(code) {
            // Real arrow keys carry these; system hotkeys like Mission Control (⌃↑) are
            // defined with the Fn bit and don't match without it.
            flags.insert([.maskSecondaryFn, .maskNumericPad])
        }
        e.flags = flags
        e.post(tap: .cghidEventTap)
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
    }

    // US layout. Characters with a key are typed as real key presses so games, which read
    // the virtual keycode rather than the text, see the right key.
    private static let plainKeys: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "\n": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48, " ": 49, "`": 50,
    ]
    private static let shiftedKeys: [Character: CGKeyCode] = [
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23, "+": 24, "(": 25, "&": 26, "_": 27,
        "*": 28, ")": 29, "}": 30, "{": 33, "\"": 39, ":": 41, "|": 42, "<": 43, "?": 44, ">": 47, "~": 50,
    ]

    private func type(_ text: String) {
        for ch in text {
            if let code = Injector.plainKeys[ch] {
                tap(code, shift: false)
            } else if ch.isUppercase, let code = Injector.plainKeys[Character(ch.lowercased())] {
                tap(code, shift: true)
            } else if let code = Injector.shiftedKeys[ch] {
                tap(code, shift: true)
            } else {
                typeUnicode(ch)
            }
        }
    }

    private func tap(_ code: CGKeyCode, shift: Bool) {
        var flags = modifiers
        if shift { flags.insert(.maskShift) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    private func typeUnicode(_ ch: Character) {
        var units = Array(String(ch).utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            e.post(tap: .cghidEventTap)
        }
    }

    func releaseAll() {
        for code in heldKeys { key(code, down: false) }
        if leftDown { button(.left, down: false) }
        if rightDown { button(.right, down: false) }
        modifiers = []
    }
}
