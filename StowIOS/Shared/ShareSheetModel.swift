import Foundation
import StowShared

/// State behind the share sheet: the link, its title, the workspace chips and Save.
@MainActor
final class ShareSheetModel: ObservableObject {
    typealias TitleFetcher = @Sendable (URL) async -> String?

    let url: URL
    let workspaces: [Workspace]
    @Published var selectedWorkspaceId: UUID?
    @Published private(set) var title: String
    @Published private(set) var isFetchingTitle = false

    private let sharedTitle: String?
    private var fetchedTitle: String?
    private let model: AppModel
    private let inbox: ShareInbox
    private let fetchTitle: TitleFetcher

    init(url: URL, sharedTitle: String?, store: DataStore, inbox: ShareInbox, fetchTitle: @escaping TitleFetcher) {
        self.url = url
        self.sharedTitle = sharedTitle
        self.inbox = inbox
        self.fetchTitle = fetchTitle
        let model = AppModel(store: store)
        self.model = model
        workspaces = model.workspaces
        selectedWorkspaceId = ShareSaver.defaultWorkspaceId(in: model.state)
        title = ShareSaver.title(shared: sharedTitle, fetched: nil, url: url)
    }

    var host: String { url.host ?? url.absoluteString }

    func loadTitle() async {
        isFetchingTitle = true
        fetchedTitle = await fetchTitle(url)
        isFetchingTitle = false
        title = ShareSaver.title(shared: sharedTitle, fetched: fetchedTitle, url: url)
    }

    @discardableResult
    func save() -> UUID? {
        guard let target = selectedWorkspaceId ?? workspaces.first?.id else { return nil }
        return ShareSaver.save(url: url, title: title, toWorkspace: target, model: model, inbox: inbox)
    }

    /// Save tapped while the title is still loading waits a moment for it, so the link
    /// rarely lands titled with just its host.
    @discardableResult
    func saveWhenTitleIsReady(timeout: Duration = .seconds(1.5)) async -> UUID? {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while isFetchingTitle, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return save()
    }

    /// Fetches through LinkTitleService, the same path the app uses for pasted links.
    static let liveTitleFetcher: TitleFetcher = { url in
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                LinkTitleService.shared.fetchTitle(for: url, linkId: UUID()) { title in
                    continuation.resume(returning: title)
                }
            }
        }
    }
}
