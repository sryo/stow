import AppKit

/// A BaseControl that can take keyboard focus with Tab, draws an accent ring while
/// focused, and performs its action on Space or Return.
@MainActor
class FocusableControl: BaseControl {
    private(set) var isFocused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .none
    }

    /// Clicks don't move focus (as with system buttons); Tab does.
    override var acceptsFirstResponder: Bool {
        guard isEnabled else { return false }
        return NSApp.currentEvent?.type != .leftMouseDown
    }

    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        isFocused = true
        focusStateChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isFocused = false
        focusStateChanged()
        return true
    }

    override func keyDown(with event: NSEvent) {
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
