import Foundation

/// What a controller control does on the computer.
enum ControlAction: Codable, Equatable, Hashable {
    case none
    case key(Int)          // macOS virtual keycode (hosts translate for Windows)
    case mouseLeft
    case mouseRight
    case mouseLook         // sticks only: the stick moves the pointer

    var label: String {
        switch self {
        case .none: return "Nothing"
        case .key(let code): return KeyCatalog.name(for: code)
        case .mouseLeft: return "Left click"
        case .mouseRight: return "Right click"
        case .mouseLook: return "Mouse look"
        }
    }

    /// Fits on a key cap.
    var shortLabel: String {
        switch self {
        case .mouseLeft: return "L click"
        case .mouseRight: return "R click"
        case .mouseLook: return "look"
        default: return label
        }
    }
}

/// Every control on an extended gamepad, as the user sees it.
enum Control: String, Codable, CaseIterable, Identifiable {
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case rightStick
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case a, b, x, y
    case l1, r1, l2, r2, l3, r3
    case menu, options

    var id: String { rawValue }

    var label: String {
        switch self {
        case .leftStickUp: return "Left stick up"
        case .leftStickDown: return "Left stick down"
        case .leftStickLeft: return "Left stick left"
        case .leftStickRight: return "Left stick right"
        case .rightStick: return "Right stick"
        case .dpadUp: return "D-pad up"
        case .dpadDown: return "D-pad down"
        case .dpadLeft: return "D-pad left"
        case .dpadRight: return "D-pad right"
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l1: return "L1 (left bumper)"
        case .r1: return "R1 (right bumper)"
        case .l2: return "L2 (left trigger)"
        case .r2: return "R2 (right trigger)"
        case .l3: return "L3 (left stick click)"
        case .r3: return "R3 (right stick click)"
        case .menu: return "Menu / Start"
        case .options: return "Options / Select"
        }
    }

    static let sections: [(String, [Control])] = [
        ("Left stick", [.leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight]),
        ("Right stick", [.rightStick]),
        ("D-pad", [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]),
        ("Buttons", [.a, .b, .x, .y]),
        ("Bumpers and triggers", [.l1, .r1, .l2, .r2]),
        ("Stick clicks", [.l3, .r3]),
        ("Menu", [.menu, .options]),
    ]
}

struct ControllerProfile: Codable, Equatable {
    var name: String
    var bindings: [Control: ControlAction]

    subscript(control: Control) -> ControlAction {
        get { bindings[control] ?? .none }
        set { bindings[control] = newValue }
    }

    /// WASD + mouse look, the way most keyboard games expect.
    static let fps = ControllerProfile(name: "FPS", bindings: [
        .leftStickUp: .key(13), .leftStickDown: .key(1), .leftStickLeft: .key(0), .leftStickRight: .key(2),
        .rightStick: .mouseLook,
        .dpadUp: .key(126), .dpadDown: .key(125), .dpadLeft: .key(123), .dpadRight: .key(124),
        .a: .key(49), .b: .key(59), .x: .key(15), .y: .key(3),
        .l1: .key(12), .r1: .key(14), .l2: .mouseRight, .r2: .mouseLeft,
        .l3: .key(56), .r3: .key(9),
        .menu: .key(53), .options: .key(48),
    ])

    /// MapleStory's keyboard defaults: arrows move, alt jumps, ctrl attacks, z picks up.
    static let mapleStory = ControllerProfile(name: "MapleStory", bindings: [
        .leftStickUp: .key(126), .leftStickDown: .key(125), .leftStickLeft: .key(123), .leftStickRight: .key(124),
        .rightStick: .none,
        .dpadUp: .key(126), .dpadDown: .key(125), .dpadLeft: .key(123), .dpadRight: .key(124),
        .a: .key(58), .b: .key(59), .x: .key(6), .y: .key(7),
        .l1: .key(0), .r1: .key(1), .l2: .key(56), .r2: .key(49),
        .l3: .key(8), .r3: .key(9),
        .menu: .key(53), .options: .key(36),
    ])

    /// Arrow keys and enter/escape: menus, launchers, 2D games.
    static let arrows = ControllerProfile(name: "Arrows", bindings: [
        .leftStickUp: .key(126), .leftStickDown: .key(125), .leftStickLeft: .key(123), .leftStickRight: .key(124),
        .rightStick: .mouseLook,
        .dpadUp: .key(126), .dpadDown: .key(125), .dpadLeft: .key(123), .dpadRight: .key(124),
        .a: .key(36), .b: .key(53), .x: .key(49), .y: .key(48),
        .l1: .key(33), .r1: .key(30), .l2: .mouseRight, .r2: .mouseLeft,
        .l3: .key(56), .r3: .key(59),
        .menu: .key(53), .options: .key(48),
    ])

    static let presets: [ControllerProfile] = [.fps, .mapleStory, .arrows]

    private static let key = "controllerProfile"

    static func load() -> ControllerProfile {
        if let data = UserDefaults.standard.data(forKey: key),
           let profile = try? JSONDecoder().decode(ControllerProfile.self, from: data) {
            return profile
        }
        return .fps
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: ControllerProfile.key)
        }
    }
}

/// Keys the user can bind, by macOS virtual keycode.
enum KeyCatalog {
    static let groups: [(String, [(String, Int)])] = [
        ("Letters", [("a", 0), ("b", 11), ("c", 8), ("d", 2), ("e", 14), ("f", 3), ("g", 5), ("h", 4), ("i", 34), ("j", 38), ("k", 40), ("l", 37), ("m", 46), ("n", 45), ("o", 31), ("p", 35), ("q", 12), ("r", 15), ("s", 1), ("t", 17), ("u", 32), ("v", 9), ("w", 13), ("x", 7), ("y", 16), ("z", 6)]),
        ("Numbers", [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29)]),
        ("Common", [("space", 49), ("enter", 36), ("tab", 48), ("esc", 53), ("backspace", 51), ("shift", 56), ("ctrl", 59), ("alt / option", 58), ("cmd / win", 55)]),
        ("Arrows", [("up", 126), ("down", 125), ("left", 123), ("right", 124)]),
        ("Function keys", [("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97), ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111)]),
        ("Symbols", [("-", 27), ("=", 24), ("[", 33), ("]", 30), ("\\", 42), (";", 41), ("'", 39), (",", 43), (".", 47), ("/", 44), ("`", 50)]),
    ]

    static func name(for code: Int) -> String {
        for (_, keys) in groups {
            if let hit = keys.first(where: { $0.1 == code }) { return hit.0 }
        }
        return "key \(code)"
    }
}
