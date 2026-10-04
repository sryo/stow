import AppKit

/// The one toast: a pill near the bottom of Stow's window, with an optional action
/// ("Archived “Lisbon”  Undo", "Copied", "Allow Stow to control Arc  Fix"). It floats
/// in its own child window so it shows over the rail as well as the page. A new toast
/// replaces the one showing.
@MainActor
enum Toast {
    /// The button at the end of the pill.
    struct Action {
        let title: String
        let handler: () -> Void

        static func undo(_ handler: @escaping () -> Void) -> Action { Action(title: "Undo", handler: handler) }
    }

    /// Inside the window's bottom edge, or just below the window (under the Tabline strip).
    enum Placement { case bottom, below }

    /// Identifies one showing, so a caller only closes its own toast.
    struct Token: Equatable { fileprivate let id: Int }

    /// Long enough to reach an Undo or Fix button.
    static let duration: TimeInterval = 6
    /// For a confirmation with nothing to click ("Copied").
    static let briefDuration: TimeInterval = 1.6

    private struct Showing {
        let token: Token
        let message: String
        let panel: NSPanel
        let onExpire: (() -> Void)?
        let timer: Timer
    }

    private static var current: Showing?
    private static var nextId = 0

    /// Shows `message` at the bottom of `window`. `onExpire` runs when the toast times out
    /// or is replaced, not when its action is clicked or it's closed with `expired: false`.
    @discardableResult
    static func show(_ message: String, action: Action? = nil, in window: NSWindow?,
                     duration: TimeInterval = Toast.duration, placement: Placement = .bottom,
                     onExpire: (() -> Void)? = nil) -> Token? {
        dismiss(expired: true)
        guard let window else { onExpire?(); return nil }
        nextId += 1
        let token = Token(id: nextId)
        let view = ToastView(message: message, actionTitle: action?.title)
        let size = view.fittingSize
        // Centered under the window; in the 52pt rail it's wider than the window, so it
        // stays on screen rather than inside the window.
        var x = window.frame.midX - size.width / 2
        if let screen = window.screen?.visibleFrame {
            x = min(max(x, screen.minX + 8), screen.maxX - 8 - size.width)
        }
        var y = window.frame.minY + 14
        if placement == .below {
            y = window.frame.minY - 6 - size.height
            if let screen = window.screen?.visibleFrame, y < screen.minY { y = window.frame.maxY + 6 }
        }
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        let panel = ToastPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = window.level
        panel.hidesOnDeactivate = false
        panel.contentView = view
        panel.isReleasedWhenClosed = false
        if let action {
            view.onAction = {
                guard current?.token == token else { return }
                action.handler()
                dismiss(expired: false)
            }
        }
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        let hint = action?.title == "Undo" ? " Press Command Z to undo." : ""
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(message).\(hint)",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            MainActor.assumeIsolated { dismiss(token, expired: true) }
        }
        current = Showing(token: token, message: message, panel: panel, onExpire: onExpire, timer: timer)
        return token
    }

    /// Closes the toast; `expired` runs its expiry (an undo window is over).
    static func dismiss(expired: Bool) {
        guard let toast = current else { return }
        current = nil
        toast.timer.invalidate()
        if expired { toast.onExpire?() }
        let panel = toast.panel
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            close(panel)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { close(panel) } })
        }
    }

    /// Closes the toast only if it's still the one `token` showed.
    static func dismiss(_ token: Token?, expired: Bool) {
        guard let token, current?.token == token else { return }
        dismiss(expired: expired)
    }

    private static func close(_ panel: NSPanel) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    static var isShowing: Bool { current != nil }
    static var currentMessage: String? { current?.message }

    /// Clicks the action button the way a person would, for tests.
    static func performAction() {
        (current?.panel.contentView as? ToastView)?.performActionForTesting()
    }
}

/// Never key, so clicking the pill leaves focus in the list; its button takes the
/// first click.
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ToastView: NSView {
    var onAction: (() -> Void)?
    private let label: NSTextField
    private let button: FlyoutButton?

    init(message: String, actionTitle: String?) {
        label = FlyoutLabel.text(message, size: 12.5, weight: .medium)
        button = actionTitle.map { FlyoutButton($0, style: .primary, height: 22, fontSize: 12) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        addSubview(label)
        if let button {
            button.target = self
            button.action = #selector(actionTapped)
            addSubview(button)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(message)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var fittingSize: NSSize {
        let text = FlyoutLabel.fittingWidth(of: label)
        guard let button else { return NSSize(width: 14 + text + 14, height: 36) }
        return NSSize(width: 14 + text + 6 + 12 + button.fittingWidth + 8, height: 36)
    }

    override func layout() {
        super.layout()
        var labelEnd = bounds.width - 14
        if let button {
            let w = button.fittingWidth
            button.frame = NSRect(x: bounds.width - 8 - w, y: (bounds.height - 22) / 2, width: w, height: 22)
            labelEnd = button.frame.minX - 12
        }
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 14, y: (bounds.height - h) / 2, width: labelEnd - 14, height: h)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = flyoutCG(FlyoutColors.background)
        layer?.borderWidth = 0.5
        layer?.borderColor = flyoutCG(FlyoutColors.line)
        label.textColor = FlyoutColors.ink
    }

    @objc private func actionTapped() { onAction?() }

    func performActionForTesting() {
        button?.performAction()
    }
}
