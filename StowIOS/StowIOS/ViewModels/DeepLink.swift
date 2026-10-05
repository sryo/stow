import Foundation
import StowShared

/// `stow://open` links from the widget and the Live Activity.
@MainActor
enum DeepLink {
    /// Selects the link's workspace, when it names one that exists, and returns the web
    /// page to open. Returns nil, and switches nothing, for anything that isn't http(s).
    static func handle(_ url: URL, model: AppModel) -> URL? {
        guard let target = StowActivityAttributes.target(ofDeepLink: url) else { return nil }
        if let workspace = StowActivityAttributes.workspace(ofDeepLink: url),
           model.workspaces.contains(where: { $0.id == workspace }) {
            model.selectWorkspace(id: workspace)
        }
        return target
    }
}
