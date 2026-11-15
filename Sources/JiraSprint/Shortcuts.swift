import SwiftUI

enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case nextStory, previousStory, nextQuery, previousQuery
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9
    case openSelected, actions, cancel, refresh, copy, openConfig, closeWindow

    static let globalCases = allCases
}

struct ShortcutBinding: Equatable, Sendable {
    let key: String
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool

    static func parse(_ source: String) -> ShortcutBinding? {
        let input = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let parts = input.split(separator: "-").map(String.init)
        var command = false, shift = false, option = false, control = false
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "cmd", "command": command = true
            case "shift": shift = true
            case "alt", "option": option = true
            case "ctrl", "control": control = true
            default: return nil
            }
        }
        guard var key = parts.last?.lowercased() else { return nil }
        if parts.count == 1, input.count == 1, input.first?.isUppercase == true {
            shift = true
            key = input.lowercased()
        }
        key = [
            "return": "enter", "esc": "escape", "spacebar": "space",
            "uparrow": "up", "downarrow": "down", "leftarrow": "left", "rightarrow": "right",
        ][key] ?? key
        let validSpecial = ["enter", "escape", "space", "up", "down", "left", "right", "tab"]
        guard validSpecial.contains(key) || key.count == 1 else { return nil }
        return ShortcutBinding(key: key, command: command, shift: shift, option: option, control: control)
    }

    func matches(_ press: KeyPress) -> Bool {
        let key: String
        switch press.key {
        case .return: key = "enter"
        case .escape: key = "escape"
        case .space: key = "space"
        case .upArrow: key = "up"
        case .downArrow: key = "down"
        case .leftArrow: key = "left"
        case .rightArrow: key = "right"
        case .tab: key = "tab"
        default: key = press.characters.lowercased()
        }
        let shifted = press.modifiers.contains(.shift)
            || (press.characters.count == 1 && press.characters.first?.isUppercase == true)
        return self.key == key && command == press.modifiers.contains(.command)
            && shift == shifted && option == press.modifiers.contains(.option)
            && control == press.modifiers.contains(.control)
    }

    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "enter": equivalent = .return
        case "escape": equivalent = .escape
        case "space": equivalent = .space
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "tab": equivalent = .tab
        default:
            guard let character = key.first else { return nil }
            equivalent = KeyEquivalent(character)
        }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return modifiers
    }

    var display: String {
        if shift, !command, !option, !control, key.count == 1, key.first?.isLetter == true {
            return key.uppercased()
        }
        let name = [
            "enter": "↵", "escape": "esc", "space": "space", "up": "↑",
            "down": "↓", "left": "←", "right": "→", "tab": "tab",
        ][key] ?? key
        let displayKey = shift && key.count == 1 ? name.uppercased() : name
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + displayKey
    }
}

struct ShortcutMap: Sendable {
    private var values: [ShortcutAction: [ShortcutBinding]]

    static let defaults: [ShortcutAction: [String]] = [
        .nextStory: ["j", "down"], .previousStory: ["k", "up"],
        .nextQuery: ["l", "]"], .previousQuery: ["h", "["],
        .tab1: ["1"], .tab2: ["2"], .tab3: ["3"], .tab4: ["4"], .tab5: ["5"],
        .tab6: ["6"], .tab7: ["7"], .tab8: ["8"], .tab9: ["9"],
        .openSelected: ["enter", "o", "cmd-enter"], .actions: ["a"], .cancel: ["escape"],
        .refresh: ["r", "cmd-r"], .copy: ["y"],
        .openConfig: ["cmd-shift-o"], .closeWindow: ["cmd-w"],
    ]

    static let standard = ShortcutMap(overrides: nil)

    init(overrides: [String: [String]]?) {
        values = [:]
        for action in ShortcutAction.allCases {
            let sources = overrides?[action.rawValue] ?? Self.defaults[action] ?? []
            values[action] = sources.compactMap(ShortcutBinding.parse)
        }
    }

    func action(for press: KeyPress, in allowed: [ShortcutAction] = ShortcutAction.globalCases) -> ShortcutAction? {
        allowed.first { action in values[action]?.contains(where: { $0.matches(press) }) == true }
    }

    func keyboardShortcut(for action: ShortcutAction, preferred: String? = nil) -> KeyboardShortcut? {
        let bindings = values[action] ?? []
        if let preferred, let match = bindings.first(where: { $0 == ShortcutBinding.parse(preferred) }) {
            return match.keyboardShortcut
        }
        return bindings.first?.keyboardShortcut
    }

    func display(for action: ShortcutAction) -> String {
        values[action]?.first?.display ?? "—"
    }
}
