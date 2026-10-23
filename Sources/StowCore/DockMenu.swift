import AppKit
import StowShared

/// The Dock icon's right-click menu: the workspace switcher, current one checked.
@MainActor
enum DockMenu {
    static func make(model: AppModel, onSelect: @escaping (UUID) -> Void) -> NSMenu {
        WorkspaceSwitcherMenu.make(
            workspaces: model.workspaces.map { .init(id: $0.id, name: $0.name, colorId: $0.colorId) },
            current: model.state.isSettingsSelected ? nil : model.currentWorkspace.id,
            onSelect: onSelect)
    }
}
