import Foundation
import StowShared

/// A link the share extension saved, kept until the app has it in memory.
struct PendingShare: Codable, Equatable {
    let workspaceId: UUID
    let node: Node
}

/// The share extension writes data.json through its own AppModel, but a running app holds
/// an older copy in memory and would overwrite the link on its next save. The extension
/// therefore also drops each saved link here, and the app absorbs them when it becomes
/// active and uploads them.
struct ShareInbox {
    static let key = "StowPendingShares"
    let defaults: UserDefaults

    init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    var pending: [PendingShare] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([PendingShare].self, from: data)) ?? []
    }

    func append(_ share: PendingShare) {
        let all = pending + [share]
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func drain() -> [PendingShare] {
        let all = pending
        defaults.removeObject(forKey: Self.key)
        return all
    }
}

@MainActor
enum ShareSaver {
    /// The workspace last opened in the app, or the first one.
    static func defaultWorkspaceId(in state: AppState) -> UUID? {
        if let selected = state.selectedWorkspaceId, state.workspaces.contains(where: { $0.id == selected }) {
            return selected
        }
        return state.workspaces.first?.id
    }

    /// Saves through AppModel (so the link lands in data.json like any other edit) and
    /// queues it for the app. Returns the new link's id.
    @discardableResult
    static func save(url: URL, title: String, toWorkspace workspaceId: UUID, model: AppModel, inbox: ShareInbox) -> UUID? {
        guard !model.workspaces.isEmpty else { return nil }
        let target = model.workspaces.contains(where: { $0.id == workspaceId })
            ? workspaceId
            : (defaultWorkspaceId(in: model.state) ?? model.currentWorkspace.id)

        let id = model.addLink(urlString: url.absoluteString, title: title, parentId: nil)
        if target != model.currentWorkspace.id {
            model.moveNodeToWorkspace(id: id, workspaceId: target)
        }
        if let node = node(id, in: model) {
            inbox.append(PendingShare(workspaceId: target, node: node))
        }
        return id
    }

    /// Adds every queued link the app doesn't already hold. Returns how many were added.
    @discardableResult
    static func absorb(inbox: ShareInbox, into model: AppModel) -> Int {
        var added = 0
        for share in inbox.drain() where node(share.node.id, in: model) == nil {
            let workspaceId = model.workspaces.contains(where: { $0.id == share.workspaceId })
                ? share.workspaceId
                : model.currentWorkspace.id
            if model.upsertNodeFromSync(node: share.node, workspaceId: workspaceId, parentId: nil) {
                added += 1
            }
        }
        return added
    }

    /// The sharing app's title wins unless it is just the address; then a fetched title;
    /// then the host.
    nonisolated static func title(shared: String?, fetched: String?, url: URL) -> String {
        let candidates = [shared, fetched].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let address = [url.absoluteString, url.host].compactMap { $0 }
        if let title = candidates.first(where: { !$0.isEmpty && !address.contains($0) }) {
            return title
        }
        return url.host ?? url.absoluteString
    }

    private static func node(_ id: UUID, in model: AppModel) -> Node? {
        for workspace in model.workspaces {
            if let found = model.findNode(id: id, in: workspace.items) { return found }
        }
        return nil
    }
}
