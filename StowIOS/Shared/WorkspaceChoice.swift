import Foundation
import StowShared

/// Which workspace a surface outside the list shows: whatever is open in the app, or a
/// specific one. The Live Activity and each widget hold their own choice.
enum WorkspaceChoice: Hashable, Sendable {
    case current
    case workspace(UUID)

    static let currentStorageValue = "current"

    init(storageValue: String?) {
        if let storageValue, let id = UUID(uuidString: storageValue) {
            self = .workspace(id)
        } else {
            self = .current
        }
    }

    var storageValue: String {
        switch self {
        case .current: return Self.currentStorageValue
        case .workspace(let id): return id.uuidString
        }
    }

    /// A pinned workspace that no longer exists falls back to the open one, and the open
    /// one falls back to the first.
    func resolve(workspaces: [Workspace], currentId: UUID?) -> Workspace? {
        if case .workspace(let id) = self, let pinned = workspaces.first(where: { $0.id == id }) {
            return pinned
        }
        return workspaces.first(where: { $0.id == currentId }) ?? workspaces.first
    }

    func resolve(in state: AppState) -> Workspace? {
        resolve(workspaces: state.workspaces, currentId: state.selectedWorkspaceId)
    }
}
