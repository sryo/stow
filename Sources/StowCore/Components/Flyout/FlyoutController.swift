import AppKit

/// Owns a stack of FlyoutPanels: one root shown from a column or an anchor, and children
/// pushed beside it (All shortcuts beside the app sheet, a nested folder beside its
/// parent). It keeps the one outside-click monitor and routes Esc: a child's Esc closes
/// only that child, a root's runs the owner's handler.
@MainActor
final class FlyoutController {
    private struct Entry {
        let id: AnyHashable
        let panel: FlyoutPanel
    }

    private var entries: [Entry] = []
    private weak var host: NSWindow?
    private var monitor: Any?

    /// A click outside every flyout. Without a handler it closes them all; owners that
    /// keep state about what's open (an editor that commits its name) close through
    /// their own path instead.
    var onOutsideClick: (() -> Void)?

    var isOpen: Bool { !entries.isEmpty }
    var openIds: [AnyHashable] { entries.map(\.id) }
    var panels: [FlyoutPanel] { entries.map(\.panel) }

    func isOpen(id: AnyHashable) -> Bool { entries.contains { $0.id == id } }

    /// Shows `panel` as the root flyout. Showing the open root again repositions it and
    /// keeps its children; any other root closes first.
    func show(_ panel: FlyoutPanel, id: AnyHashable, content: NSView, size: NSSize, anchor: NSRect,
              edge: FlyoutPanel.Edge, topInset: CGFloat, parent: NSWindow, onEscape: (() -> Void)? = nil) {
        if entries.first?.id != id || entries.first?.panel !== panel {
            closeAll()
            entries = [Entry(id: id, panel: panel)]
        }
        host = parent
        panel.onEscape = onEscape ?? { [weak self] in self?.close(id: id) }
        panel.present(content, size: size, anchor: anchor, edge: edge, topInset: topInset, parent: parent)
        installMonitor()
    }

    /// Pushes `panel` beside the flyout below it in the stack, its arrow on `anchor` (the
    /// row that opened it, in screen coordinates). Pushing an open child again
    /// repositions it and closes whatever was above it.
    func push(_ panel: FlyoutPanel, id: AnyHashable, content: NSView, size: NSSize, anchor: NSRect,
              topInset: CGFloat, onEscape: (() -> Void)? = nil) {
        guard let host, !entries.isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            guard index > 0 else { return }
            closeEntries(from: index + 1)
        } else {
            entries.append(Entry(id: id, panel: panel))
        }
        let below = entries[entries.count - 2].panel
        panel.onEscape = onEscape ?? { [weak self] in self?.close(id: id) }
        panel.present(content, size: size, anchor: anchor, edge: .beside(column: below.frame),
                      topInset: topInset, parent: host)
        installMonitor()
    }

    /// Closes the flyout with `id` if it's open, otherwise runs `open`.
    func toggle(id: AnyHashable, open: () -> Void) {
        if isOpen(id: id) { close(id: id) } else { open() }
    }

    /// Closes the flyout with `id` and everything pushed above it. The flyout below it,
    /// if any, takes the keyboard back.
    func close(id: AnyHashable) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        closeEntries(from: index)
        if let top = entries.last?.panel, top.canBecomeKey, top.isVisible { top.makeKey() }
    }

    func closeTop() {
        if let id = entries.last?.id { close(id: id) }
    }

    func closeAll() {
        closeEntries(from: 0)
    }

    private func closeEntries(from index: Int) {
        guard index < entries.count else { return }
        for entry in entries[index...].reversed() {
            entry.panel.dismiss()
        }
        entries.removeSubrange(index...)
        if entries.isEmpty { removeMonitor() }
    }

    // MARK: Outside clicks

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isOpen else { return event }
            if FlyoutDismissPolicy.clickCloses(window: event.window, stack: self.panels, host: self.host) {
                if let onOutsideClick = self.onOutsideClick { onOutsideClick() } else { self.closeAll() }
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
