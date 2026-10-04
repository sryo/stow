import AppKit

/// Whether a click seen by FlyoutController's outside-click monitor closes the open
/// flyouts. Every panel in the stack (pushed children too), the window that opened them
/// (which handles its own clicks), the color panel, menus and popovers count as inside.
enum FlyoutDismissPolicy {
    static func clickCloses(inStack: Bool, inHost: Bool, isColorPanel: Bool, windowClassName: String?) -> Bool {
        if inStack || inHost || isColorPanel { return false }
        guard let name = windowClassName else { return true }
        return !(name.contains("Menu") || name.contains("Popover"))
    }

    @MainActor
    static func clickCloses(window: NSWindow?, stack: [NSWindow], host: NSWindow?) -> Bool {
        guard let window else { return true }
        return clickCloses(inStack: stack.contains { $0 === window }, inHost: window === host,
                           isColorPanel: window is NSColorPanel, windowClassName: window.className)
    }
}
