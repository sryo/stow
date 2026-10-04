import AppKit

/// What happens to links, wherever they're clicked (list, mosaic, rail, Tabline, global
/// shortcut): opening one or a folder of them in the right browser, stowing the front tab
/// or a URL, and fetching a new link's title.
@MainActor
final class LinkActions {
    private let model: AppModel
    /// The window toasts appear in.
    private let window: () -> NSWindow?

    init(model: AppModel, window: @escaping () -> NSWindow?) {
        self.model = model
        self.window = window
    }

    /// Switches to the link's tab if it's open in any browser; otherwise opens it in the
    /// workspace's "Opens in" browser (by default the browser you're using). Holding Option
    /// opens a fresh tab instead. `override` is a one-off Open in ▸ choice from the link's menu.
    func openLink(_ link: Link, in override: OpensIn? = nil) {
        guard let url = URL(string: link.url) else { return }
        let target = override.map {
            LinkTarget(bundleId: $0.bundleId, profile: $0.profile)
        } ?? LinkTarget.forWorkspace(model.activeWorkspaceId)
        Task.detached(priority: .userInitiated) {
            if target.focusesOpenTab, await BrowserTabService.focusIfOpen(url: url) { return }
            await MainActor.run { BrowserManager.open(url: url, bundleId: target.bundleId, profile: target.profile) }
        }
    }

    func openLinksInFolder(_ folder: Folder) {
        let links = collectLinks(in: folder)
        guard !links.isEmpty else { return }
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

    private func collectLinks(in folder: Folder) -> [Link] {
        folder.children.flattenLinks()
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

    /// The one stow path: top of the workspace, once per page, then a title fetch.
    @discardableResult
    func stow(url: URL, title: String, into workspaceId: UUID?) -> AppModel.StowResult {
        let result = model.stowLink(url: url, title: title, workspaceId: workspaceId)
        switch result {
        case .added(let id):
            fetchTitleForNewLink(id: id, url: url)
        case .alreadyPresent(let id):
            let name = model.workspaces.first { ws in ws.items.flattenIds().contains(id) }?.name ?? model.activeWorkspace.name
            Toast.show("Already in \(name)", in: window(), duration: Toast.briefDuration * 2)
        }
        return result
    }

    func fetchTitleForNewLink(id: UUID, url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        LinkTitleService.shared.fetchTitle(for: url, linkId: id) { [weak self] title in
            guard let self, let title else { return }
            _ = self.model.updateLinkTitleIfDefault(id: id, newTitle: title)
        }
    }
}
