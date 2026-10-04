import Foundation
import StowShared

/// "Dynamic Island & Lock Screen" and its "Shows" choice. Both stay on this iPhone.
struct LiveActivitySettings {
    /// The key the old About toggle wrote, so an existing choice carries over.
    static let enabledKey = "StowShowInDynamicIsland"
    static let showsKey = "StowLiveActivityShows"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var shows: WorkspaceChoice {
        get { WorkspaceChoice(storageValue: defaults.string(forKey: Self.showsKey)) }
        nonmutating set { defaults.set(newValue.storageValue, forKey: Self.showsKey) }
    }

    func workspace(in model: AppModel) -> Workspace {
        shows.resolve(workspaces: model.workspaces, currentId: model.state.selectedWorkspaceId) ?? model.currentWorkspace
    }

    struct Option: Hashable {
        let choice: WorkspaceChoice
        let title: String
    }

    static func options(for workspaces: [Workspace]) -> [Option] {
        [Option(choice: .current, title: "Open workspace")]
            + workspaces.map { Option(choice: .workspace($0.id), title: $0.name) }
    }
}
