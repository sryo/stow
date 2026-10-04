import AppKit
import Carbon

@MainActor
protocol GlobalHotkeyServiceDelegate: AnyObject {
    func hotkeyService(_ service: GlobalHotkeyService, didTrigger action: HotkeyAction)
}

/// Registers Stow's global hotkeys (one per HotkeyAction) with Carbon, which works from
/// any app without Accessibility access.
@MainActor
final class GlobalHotkeyService {
    static let shared = GlobalHotkeyService()

    weak var delegate: GlobalHotkeyServiceDelegate?

    private var hotkeys: [HotkeyAction: (ref: EventHotKeyRef, shortcut: KeyboardShortcut)] = [:]
    private var eventHandler: EventHandlerRef?

    private static let signature: OSType = 0x53544F57 // "STOW"

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyNotification(_:)),
            name: .globalHotkeyTriggered,
            object: nil
        )
    }

    @objc private func handleHotkeyNotification(_ note: Notification) {
        guard let id = note.userInfo?["id"] as? UInt32, let action = HotkeyAction(hotkeyId: id) else { return }
        delegate?.hotkeyService(self, didTrigger: action)
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), globalHotkeyHandler, 1, &eventType, nil, &eventHandler)
    }

    /// Registers `shortcut` for `action`, replacing what it had. Returns false when
    /// macOS refuses it (another app holds it).
    @discardableResult
    func register(_ shortcut: KeyboardShortcut, for action: HotkeyAction) -> Bool {
        unregister(action)
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.hotkeyId)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("GlobalHotkeyService: couldn't register \(shortcut.displayString) for \(action), status \(status)")
            return false
        }
        hotkeys[action] = (ref, shortcut)
        return true
    }

    func unregister(_ action: HotkeyAction) {
        guard let entry = hotkeys.removeValue(forKey: action) else { return }
        UnregisterEventHotKey(entry.ref)
    }

    func unregisterAll() {
        HotkeyAction.allCases.forEach(unregister)
    }

    func registeredShortcut(for action: HotkeyAction) -> KeyboardShortcut? {
        hotkeys[action]?.shortcut
    }

    /// Registers every stored shortcut and drops the cleared ones.
    func apply(_ store: ShortcutStore = ShortcutStore()) {
        for action in HotkeyAction.allCases {
            if let shortcut = store.shortcut(for: action) {
                if registeredShortcut(for: action) != shortcut { register(shortcut, for: action) }
            } else {
                unregister(action)
            }
        }
    }
}

/// Carbon event handler (C function pointer, cannot capture context).
private func globalHotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
    guard status == noErr else { return status }
    NotificationCenter.default.post(name: .globalHotkeyTriggered, object: nil, userInfo: ["id": hotkeyID.id])
    return noErr
}

extension Notification.Name {
    static let globalHotkeyTriggered = Notification.Name("globalHotkeyTriggered")
}
