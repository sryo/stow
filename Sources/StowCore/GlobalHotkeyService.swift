import AppKit
import Carbon

@MainActor
protocol GlobalHotkeyServiceDelegate: AnyObject {
    func hotkeyServiceDidTrigger(_ service: GlobalHotkeyService)
}

@MainActor
final class GlobalHotkeyService {
    static let shared = GlobalHotkeyService()

    weak var delegate: GlobalHotkeyServiceDelegate?

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private static let signature: OSType = 0x53544F57 // "STOW"
    private static let hotkeyId: UInt32 = 1

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyNotification),
            name: .globalHotkeyTriggered,
            object: nil
        )
    }

    @objc private func handleHotkeyNotification() {
        delegate?.hotkeyServiceDidTrigger(self)
    }

    func register(shortcut: KeyboardShortcut) {
        unregister()

        let hotkeyID = EventHotKeyID(signature: Self.signature, id: Self.hotkeyId)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotkeyHandler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status != noErr {
            print("GlobalHotkeyService: Failed to register hotkey, status: \(status)")
        }
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
}

/// Carbon event handler (C function pointer, cannot capture context).
private func globalHotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    NotificationCenter.default.post(name: .globalHotkeyTriggered, object: nil)
    return noErr
}

extension Notification.Name {
    static let globalHotkeyTriggered = Notification.Name("globalHotkeyTriggered")
}
