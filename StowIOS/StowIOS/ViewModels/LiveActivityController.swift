import ActivityKit
import Foundation
import StowShared

/// Starts, updates and ends the workspace Live Activity.
///
/// iOS ends Live Activities on its own after roughly 8 hours (12 on the Lock Screen), and
/// the user can dismiss one at any time. `sync` is called on every foreground, so an
/// ended activity is simply requested again the next time the app is opened.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    /// ActivityKit rejects states above 4 KB; leave headroom for its own envelope.
    private static let maxStateBytes = 3_500
    private static let maxTitleLength = 40

    private var lastState: StowActivityAttributes.ContentState?

    private init() {}

    /// Brings the activity in line with `workspace`, the one Settings ▸ Shows picks. `force`
    /// pushes the state even when it matches the last one sent, which is how a dismissed or
    /// expired activity comes back. The system's Live Activities switch always wins.
    func sync(workspace: Workspace, enabled: Bool, force: Bool = false) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastState = nil
            enqueue { await Self.endAll() }
            return
        }

        let state = Self.state(for: workspace)
        if !force, state == lastState { return }
        lastState = state
        enqueue { await Self.apply(state) }
    }

    /// `Activity` isn't Sendable, so every ActivityKit call happens inside one nonisolated
    /// operation that looks the activities up itself. Operations run one after another so
    /// two quick syncs can't both request a new activity.
    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = pending
        pending = Task.detached {
            await previous?.value
            await operation()
        }
    }

    private var pending: Task<Void, Never>?

    private nonisolated static func apply(_ state: StowActivityAttributes.ContentState) async {
        let content = ActivityContent(state: state, staleDate: nil)
        let running = Activity<StowActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }

        guard let current = running.first else {
            do {
                _ = try Activity.request(attributes: StowActivityAttributes(), content: content, pushType: nil)
            } catch {
                NSLog("Stow: could not start Live Activity — \(error.localizedDescription)")
            }
            return
        }
        for extra in running.dropFirst() {
            await extra.end(nil, dismissalPolicy: .immediate)
        }
        await current.update(content)
    }

    private nonisolated static func endAll() async {
        for activity in Activity<StowActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func state(for workspace: Workspace) -> StowActivityAttributes.ContentState {
        let links = workspace.items.flattenLinks().filter { !$0.isArchived }
        let top = links.prefix(StowActivityAttributes.maxLinks).map { link in
            StowActivityAttributes.TopLink(
                title: String((link.title.isEmpty ? (link.displayDomain ?? link.url) : link.title).prefix(maxTitleLength)),
                url: link.url,
                host: String((link.displayDomain ?? "").prefix(maxTitleLength))
            )
        }

        var state = StowActivityAttributes.ContentState(
            workspaceId: workspace.id,
            name: String(workspace.name.prefix(maxTitleLength)),
            monogram: StowActivityAttributes.monogram(for: workspace.name),
            colorHex: StowTheme.RGB(workspace.colorId.color).hex,
            linkCount: links.count,
            links: Array(top)
        )
        // Long URLs can push the state past the limit; drop tiles from the end until it fits.
        let encoder = JSONEncoder()
        while !state.links.isEmpty,
              let data = try? encoder.encode(state), data.count > maxStateBytes {
            state.links.removeLast()
        }
        return state
    }
}
