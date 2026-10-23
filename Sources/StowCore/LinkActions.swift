import AppKit

/// What happens to links, wherever they're clicked (list, mosaic, rail, Tabline, global
/// shortcut): opening one or a folder of them in the right browser, stowing the front tab
/// or a URL, and fetching a new link's title.
@MainActor
final class LinkActions {
    private let model: AppModel
    /// The window toasts appear in.
    private let window: () -> NSWindow?

    /// Shows one toast: a message and how long it stays.
    typealias ToastPresenter = (_ message: String, _ duration: TimeInterval) -> Void
    /// Where a stow's toast goes when the caller doesn't name a surface: Stow's window.
    lazy var presentToast: ToastPresenter = { [weak self] message, duration in
        Toast.show(message, in: self?.window(), duration: duration)
    }
    /// Opens several links at once in the workspace's browser. Tests record instead.
    lazy var openMany: ([Link]) -> Void = { [weak self] links in self?.openInBrowser(links) }
    /// Whether Stow's window is up on screen showing the workspace, so a stow there is
    /// seen landing and needs no toast. Tests answer instead.
    lazy var isShowingWorkspace: (UUID) -> Bool = { [weak self] id in
        guard let self, let window = self.window(), window.isVisible,
              window.occlusionState.contains(.visible) else { return false }
        return self.model.state.selectedWorkspaceId == id
    }
    /// Where opens are noted, for fading links that go unopened; nil in tests.
    var recency: LinkRecency?

    /// Opens a URL in a new tab behind the front app. Tests record instead.
    lazy var openBehind: (URL, LinkTarget) -> Void = { url, target in
        BrowserManager.open(url: url, bundleId: target.bundleId, profile: target.profile, activates: false)
    }
    /// Stows the front tab. Tests record instead.
    lazy var stowFront: () -> Void = { [weak self] in self?.stowFrontTab() }

    /// Middle-click: a new tab in the workspace's browser, left behind Stow.
    func openLinkInBackground(_ link: Link) {
        guard let url = URL(string: link.url) else { return }
        noteOpened(link)
        openBehind(url, LinkTarget.forWorkspace(model.activeWorkspaceId, forceNewTab: true))
    }

    /// Saved links only; a bang's search opens through here too.
    private func noteOpened(_ link: Link) {
        if model.nodeById(link.id) != nil { recency?.noteOpened(link.id) }
    }

    /// Opening this many links or more at once asks first.
    static let confirmThreshold = 15
    /// Asks whether to open that many links. Tests answer instead.
    lazy var confirmOpening: (Int) -> Bool = { [weak self] count in self?.askToOpen(count) ?? false }

    init(model: AppModel, window: @escaping () -> NSWindow?) {
        self.model = model
        self.window = window
    }

    /// Switches to the link's tab if it's open in any browser; otherwise opens it in the
    /// workspace's "Opens in" browser (by default the browser you're using). Holding Option
    /// opens a fresh tab instead, as `newTab` (⌥Return) does. `override` is a one-off Open in ▸
    /// choice from the link's menu.
    func openLink(_ link: Link, in override: OpensIn? = nil, newTab: Bool = false) {
        guard let url = URL(string: link.url) else { return }
        noteOpened(link)
        let target = override.map {
            LinkTarget(bundleId: $0.bundleId, profile: $0.profile, focusesOpenTab: !newTab)
        } ?? LinkTarget.forWorkspace(model.activeWorkspaceId, forceNewTab: newTab || NSEvent.modifierFlags.contains(.option))
        Task.detached(priority: .userInitiated) {
            if target.focusesOpenTab, await BrowserTabService.focusIfOpen(url: url) { return }
            await MainActor.run { BrowserManager.open(url: url, bundleId: target.bundleId, profile: target.profile) }
        }
    }

    /// "Open all", from the list, its menu and the rail: the links the folder shows.
    func openLinksInFolder(_ folder: Folder) {
        let links = folder.openableLinks
        guard !links.isEmpty else { return }
        if links.count >= Self.confirmThreshold, !confirmOpening(links.count) { return }
        openMany(links)
    }

    private func askToOpen(_ count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Open \(count) links?"
        alert.informativeText = "Each one opens in its own tab."
        alert.addButton(withTitle: "Open \(count) Tabs")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func openInBrowser(_ links: [Link]) {
        links.forEach(noteOpened)
        let target = LinkTarget.forWorkspace(model.activeWorkspaceId)
        // One tabs snapshot covers every link — avoids 20 detached Tasks each
        // re-querying every running browser on bulk open.
        Task.detached(priority: .userInitiated) {
            let tabs = await BrowserTabService.tabsByCanonicalURL()
            for link in links {
                guard let url = URL(string: link.url) else { continue }
                let key = BrowserTabService.canonicalize(url)
                if target.focusesOpenTab, let tab = tabs[key], BrowserTabService.focus(tab: tab) { continue }
                await MainActor.run { BrowserManager.open(url: url, bundleId: target.bundleId, profile: target.profile) }
            }
        }
    }

    /// Saves the front tab of the browser the user was last in to the active workspace (on
    /// Settings, the one you came from). Runs from the footer, the rail's "+" and the global
    /// Stow front tab shortcut.
    func stowFrontTab() {
        guard let bundleId = ActiveBrowserTracker.shared.lastActiveBundleId else { NSSound.beep(); return }
        let workspaceId = model.activeWorkspaceId
        Task.detached(priority: .userInitiated) { [weak self] in
            let tab = BrowserTabService.frontTab(bundleId: bundleId)
            await MainActor.run {
                guard let self else { return }
                guard let tab else { self.reportFrontTabUnavailable(); return }
                self.stow(url: tab.url, title: tab.title, into: workspaceId)
            }
        }
    }

    /// The front tab couldn't be read: say so when it's Automation permission (with a
    /// way to fix it), otherwise just beep.
    func reportFrontTabUnavailable() {
        guard let browser = AppPreferences.shared.automationDeniedBrowser() else { NSSound.beep(); return }
        Toast.show("Allow Stow to control \(browser)", action: Toast.Action(title: "Fix") {
            AppPreferences.shared.openAutomationSettings()
        }, in: window())
    }

    /// The one stow path: top of the workspace, once per page, then a title fetch. It says
    /// "Stowed in X" or "Already in X" once, through `toast` (the caller's surface, such as
    /// the Tabline's strip) or else in Stow's window.
    @discardableResult
    func stow(url: URL, title: String, into workspaceId: UUID?, toast: ToastPresenter? = nil) -> AppModel.StowResult {
        let result = model.stowLink(url: url, title: title, workspaceId: workspaceId)
        let message: String
        switch result {
        case .added(let id):
            fetchTitleForNewLink(id: id, url: url)
            if let workspace = model.workspaces.first(where: { $0.items.flattenIds().contains(id) }),
               isShowingWorkspace(workspace.id) { return result }
            message = "Stowed in \(workspaceName(holding: id))"
        case .alreadyPresent(let id):
            message = "Already in \(workspaceName(holding: id))"
        }
        (toast ?? presentToast)(message, Toast.briefDuration * 2)
        return result
    }

    private func workspaceName(holding id: UUID) -> String {
        model.workspaces.first { $0.items.flattenIds().contains(id) }?.name ?? model.activeWorkspace.name
    }

    func fetchTitleForNewLink(id: UUID, url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        LinkTitleService.shared.fetchTitle(for: url, linkId: id) { [weak self] title in
            guard let self, let title else { return }
            _ = self.model.updateLinkTitleIfDefault(id: id, newTitle: title)
        }
    }
}
