import AppKit
import Carbon

/// The two global shortcuts Stow registers. Each has its own stored shortcut and its
/// own Carbon hotkey id.
enum HotkeyAction: UInt32, CaseIterable {
    case toggleStow = 1
    case stowFrontTab = 2

    var hotkeyId: UInt32 { rawValue }

    init?(hotkeyId: UInt32) { self.init(rawValue: hotkeyId) }

    var title: String {
        switch self {
        case .toggleStow: return "Toggle Stow"
        case .stowFrontTab: return "Stow front tab"
        }
    }

    /// What the shortcut does, for refusals ("⌥⌘S already stows the front tab.").
    var verbPhrase: String {
        switch self {
        case .toggleStow: return "shows and hides Stow"
        case .stowFrontTab: return "stows the front tab"
        }
    }

    /// Toggle Stow keeps the key older builds used, so a recorded shortcut survives.
    var defaultsKey: String {
        switch self {
        case .toggleStow: return UserDefaultsKeys.toggleSidebarShortcut
        case .stowFrontTab: return "stowFrontTabShortcut"
        }
    }

    /// ⌃⌥S, which no major browser binds (⇧⌘B shows the bookmarks bar), and ⌥⌘S.
    var defaultShortcut: KeyboardShortcut {
        switch self {
        case .toggleStow: return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(controlKey | optionKey))
        case .stowFrontTab: return KeyboardShortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(optionKey | cmdKey))
        }
    }
}

/// Reads and writes the global shortcuts. A missing value means the default; a cleared
/// one is stored as "none" so Clear stays cleared across launches.
struct ShortcutStore {
    static let noneMarker = "none"
    var defaults: UserDefaults = .standard

    func shortcut(for action: HotkeyAction) -> KeyboardShortcut? {
        guard let stored = defaults.object(forKey: action.defaultsKey) else { return action.defaultShortcut }
        if let string = stored as? String, string == Self.noneMarker { return nil }
        guard let data = stored as? Data else { return action.defaultShortcut }
        return try? JSONDecoder().decode(KeyboardShortcut.self, from: data)
    }

    func set(_ shortcut: KeyboardShortcut, for action: HotkeyAction) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: action.defaultsKey)
    }

    func clear(_ action: HotkeyAction) {
        defaults.set(Self.noneMarker, forKey: action.defaultsKey)
    }

    /// The action already using `shortcut`, if any.
    func action(using shortcut: KeyboardShortcut) -> HotkeyAction? {
        HotkeyAction.allCases.first { self.shortcut(for: $0) == shortcut }
    }
}

/// Why a recorded shortcut is refused or worth a warning.
enum ShortcutConflicts {
    /// Shortcuts Stow or macOS already use; these are refused.
    static let system: [KeyboardShortcut: String] = {
        let cmd = UInt32(cmdKey), ctrl = UInt32(controlKey)
        return [
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Comma), carbonModifiers: cmd): "⌘, opens Settings.",
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: cmd): "⌘Q quits apps.",
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: cmd): "⌘N makes new things.",
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_W), carbonModifiers: cmd): "⌘W closes windows.",
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_H), carbonModifiers: cmd): "⌘H hides apps.",
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: cmd): "⌘M minimizes windows.",
            KeyboardShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: cmd): "⌘Space opens Spotlight.",
            KeyboardShortcut(keyCode: UInt32(kVK_Tab), carbonModifiers: cmd): "⌘Tab switches apps.",
            KeyboardShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: ctrl): "⌃Space switches input sources.",
        ]
    }()

    /// Shortcuts the major browsers bind. A global hotkey takes them away from the
    /// browser, so recording one keeps it but shows a warning.
    static let browser: [KeyboardShortcut: String] = {
        let cmd = UInt32(cmdKey), shift = UInt32(shiftKey), opt = UInt32(optionKey)
        func k(_ code: Int, _ mods: UInt32) -> KeyboardShortcut { KeyboardShortcut(keyCode: UInt32(code), carbonModifiers: mods) }
        return [
            k(kVK_ANSI_B, cmd | shift): "shows the bookmarks bar in Chrome, Safari and Arc",
            k(kVK_ANSI_L, cmd): "focuses the address bar in every browser",
            k(kVK_ANSI_T, cmd): "opens a new tab in every browser",
            k(kVK_ANSI_T, cmd | shift): "reopens the last closed tab in every browser",
            k(kVK_ANSI_D, cmd): "bookmarks the page in every browser",
            k(kVK_ANSI_R, cmd): "reloads the page in every browser",
            k(kVK_ANSI_Y, cmd): "opens history in Chrome",
            k(kVK_ANSI_N, cmd | shift): "opens a private window in Chrome",
            k(kVK_ANSI_B, cmd | opt): "opens the bookmark manager in Chrome",
            k(kVK_ANSI_I, cmd | opt): "opens the developer tools in Chrome and Safari",
            k(kVK_ANSI_J, cmd | opt): "opens the JavaScript console in Chrome",
            k(kVK_ANSI_L, cmd | opt): "opens downloads in Chrome and shows Stow's Tabline",
            k(kVK_ANSI_A, cmd | shift): "searches tabs in Chrome",
            k(kVK_ANSI_S, cmd | shift): "opens the sidebar in Arc",
        ]
    }()

    static func systemRejection(for shortcut: KeyboardShortcut) -> String? {
        system[shortcut]
    }

    static func browserWarning(for shortcut: KeyboardShortcut) -> String? {
        browser[shortcut].map { "\(shortcut.displayString) also \($0)." }
    }

    /// Refuses the shortcut the other Stow action already uses.
    static func stowRejection(for shortcut: KeyboardShortcut, recording: HotkeyAction, store: ShortcutStore) -> String? {
        guard let owner = store.action(using: shortcut), owner != recording else { return nil }
        return "\(shortcut.displayString) already \(owner.verbPhrase)."
    }
}
