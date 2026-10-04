import AppKit
import StowShared

/// The one workspace switcher for places that stay a native menu: a "Workspaces" header,
/// then each workspace with its WorkspaceDot, its ⌘-number and a check on the current one.
/// Callers append their own items (New Workspace…, Settings…) after it.
@MainActor
enum WorkspaceSwitcherMenu {
    struct Entry {
        let id: UUID
        let name: String
        let colorId: WorkspaceColorId
    }

    static func make(workspaces: [Entry], current: UUID?, onSelect: @escaping (UUID) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Workspaces"))
        for (i, ws) in workspaces.enumerated() {
            let id = ws.id
            let item = ClosureMenuItem(title: ws.name, keyEquivalent: i < 9 ? "\(i + 1)" : "") { onSelect(id) }
            item.keyEquivalentModifierMask = .command
            item.image = WorkspaceDot.image(ws.colorId)
            item.state = ws.id == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
}

/// An NSMenuItem that runs a closure; it targets itself, so the menu keeps it alive.
final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler?() }
}
