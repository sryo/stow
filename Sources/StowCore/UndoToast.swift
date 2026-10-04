import AppKit

/// "Deleted “Research”  Undo": a pill near the bottom of Stow's window for six seconds.
/// It floats in its own child window so it shows over the rail as well as the page.
@MainActor
enum UndoToast {
    static let duration: TimeInterval = 6
    private static var current: (panel: NSPanel, onExpire: () -> Void, timer: Timer)?

    static func show(_ message: String, in window: NSWindow?, onUndo: @escaping () -> Void, onExpire: @escaping () -> Void) {
        dismiss(expired: true)
        guard let window else { onExpire(); return }
        let view = ToastView(message: message)
        let size = view.fittingSize
        // Centered under the window; in the 52pt rail it's wider than the window, so it
        // stays on screen rather than inside the window.
        let width = size.width
        var x = window.frame.midX - width / 2
        if let screen = window.screen?.visibleFrame {
            x = min(max(x, screen.minX + 8), screen.maxX - 8 - width)
        }
        let frame = NSRect(x: x, y: window.frame.minY + 14, width: width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = window.level
        panel.contentView = view
        panel.isReleasedWhenClosed = false
        view.onUndo = {
            onUndo()
            dismiss(expired: false)
        }
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(message). Press Command Z to undo.",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            MainActor.assumeIsolated { dismiss(expired: true) }
        }
        current = (panel, onExpire, timer)
    }

    /// Closes the toast; `expired` runs its expiry (the undo window is over).
    static func dismiss(expired: Bool) {
        guard let toast = current else { return }
        current = nil
        toast.timer.invalidate()
        if expired { toast.onExpire() }
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

    private static func close(_ panel: NSPanel) {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    static var isShowing: Bool { current != nil }
}

private final class ToastView: NSView {
    var onUndo: (() -> Void)?
    private let label: NSTextField
    private let undo = FlyoutButton("Undo", style: .primary, height: 22, fontSize: 12)

    init(message: String) {
        label = FlyoutLabel.text(message, size: 12.5, weight: .medium)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        addSubview(label)
        undo.target = self
        undo.action = #selector(undoTapped)
        addSubview(undo)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(message)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var fittingSize: NSSize {
        NSSize(width: 14 + ceil(label.intrinsicContentSize.width) + 6 + 12 + undo.fittingWidth + 8, height: 36)
    }

    override func layout() {
        super.layout()
        let u = undo.fittingWidth
        undo.frame = NSRect(x: bounds.width - 8 - u, y: (bounds.height - 22) / 2, width: u, height: 22)
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 14, y: (bounds.height - h) / 2, width: undo.frame.minX - 12 - 14, height: h)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = flyoutCG(FlyoutColors.background)
        layer?.borderWidth = 0.5
        layer?.borderColor = flyoutCG(FlyoutColors.line)
        label.textColor = FlyoutColors.ink
    }

    @objc private func undoTapped() { onUndo?() }
}
