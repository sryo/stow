import AppKit

/// When a focus ring shows: only once the keyboard is in use, like CSS :focus-visible.
/// A window that hands focus to its first key view as it opens draws no ring; Tab, or a
/// key pressed on the focused control, brings it.
@MainActor
enum FocusRing {
    /// Whether the focus change happening now comes from the keyboard. Tests replace it.
    /// A ⌘ shortcut that opens a window (⌘,) isn't keyboard navigation.
    static var focusCameFromKeyboard: () -> Bool = {
        guard let event = currentEvent(), event.type == .keyDown else { return false }
        return !event.modifierFlags.contains(.command)
    }

    /// The event being handled. Tests replace it.
    static var currentEvent: () -> NSEvent? = { NSApp.currentEvent }

    /// Whether a control should take focus now: from the keyboard, or from code (no
    /// event), but not as a side effect of a click or of the window opening after one,
    /// so the first Tab lands on the first control rather than past it.
    static var acceptsFocusNow: Bool {
        guard let event = currentEvent() else { return true }
        return event.type == .keyDown
    }
}

/// A BaseControl that can take keyboard focus with Tab, draws an accent ring while
/// focused from the keyboard, and performs its action on Space or Return.
@MainActor
class FocusableControl: BaseControl {
    /// Whether this control is the first responder.
    private(set) var hasFocus = false
    private var focusVisible = false
    /// Whether the focus ring shows: focused, and the keyboard is in use.
    var isFocused: Bool { hasFocus && focusVisible }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .none
    }

    /// Clicks, and windows opening after one, don't move focus (as with system buttons); Tab does.
    override var acceptsFirstResponder: Bool {
        guard isEnabled else { return false }
        return FocusRing.acceptsFocusNow
    }

    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        hasFocus = true
        focusVisible = FocusRing.focusCameFromKeyboard()
        focusStateChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        focusVisible = false
        focusStateChanged()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if hasFocus, !focusVisible {
            focusVisible = true
            focusStateChanged()
        }
        switch event.keyCode {
        case 49, 36, 76: // Space, Return, keypad Enter
            performAction()
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performAction()
        return true
    }

    /// Subclasses refresh their look; the default redraws the layer.
    func focusStateChanged() {
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
