import AppKit

/// Runs the rail for MainViewController: the workspace rail (RailView) takes over from the
/// page chrome at rail width, and its callbacks go on to the main window. The rail has no
/// Settings page: its gear opens the app sheet beside it, and a right-click on a dot opens
/// the workspace editor.
@MainActor
final class RailCoordinator {
    private unowned let main: MainViewController
    private var model: AppModel { main.model }

    let railView = RailView()
    /// The page content was hidden because the rail took over; leaving the rail shows it again.
    private var contentHiddenByRail = false

    init(main: MainViewController) {
        self.main = main
    }

    /// The rail replaces the workspace chrome (header, search, list, bottom bar) and, like
    /// the mockup, drops the traffic lights.
    func updateRailVisibility() {
        let rail = main.elasticMode == .rail
        let onSettings = model.state.isSettingsSelected
        main.topBar.isHidden = rail
        main.contentStackTrailing.isActive = !rail
        // The rail only undoes its own hiding. Otherwise which page's content shows, mid-swipe
        // included, belongs to showSettingsContent / showWorkspaceContent.
        let settingsView = main.settingsViewController.view
        if rail {
            main.contentStack.isHidden = true
            if !settingsView.isHidden { main.settingsViewController.closeFlyouts() }
            settingsView.isHidden = true
            contentHiddenByRail = true
        } else if contentHiddenByRail {
            contentHiddenByRail = false
            settingsView.isHidden = !onSettings
            main.contentStack.isHidden = onSettings
        }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            main.view.window?.standardWindowButton(kind)?.isHidden = rail
        }
        railView.isHidden = !rail
        main.updateOpenTabsPolling()
    }

    func reloadRail() {
        guard main.elasticMode == .rail, !model.state.isSettingsSelected else { return }
        let ws = model.currentWorkspace
        let editor = main.workspaceEditor
        railView.configure(
            workspaces: model.workspaces.map { RailView.WorkspaceDot(id: $0.id, name: $0.name, color: editor.shownColor(of: $0).color) },
            selectedId: ws.id,
            colorId: editor.shownColor(of: ws),
            items: ws.items
        )
        FaviconPrefetcher.shared.request(links: ws.items.flattenLinks().filter { !$0.isArchived }, in: ws.id)
    }

    func wireRail() {
        railView.onSelectWorkspace = { [weak self] id in self?.main.selectWorkspaceAndPage(id) }
        railView.onWorkspaceContextMenu = { [weak self] id, dot in
            self?.main.editWorkspace(id, from: dot, edge: .besideWindow)
        }
        railView.onNewWorkspace = { [weak self] in self?.main.promptCreateWorkspace() }
        railView.onReorderWorkspace = { [weak self] id, index in self?.model.reorderWorkspace(id: id, toIndex: index) }
        railView.onOpenLink = { [weak self] link in self?.main.links.openLink(link) }
        railView.onOpenFolder = { [weak self] folder in self?.main.links.openLinksInFolder(folder) }
        railView.onToggleTask = { [weak self] id in self?.model.toggleTaskCompletion(id: id) }
        railView.onCopySnippet = { [weak self] id in
            guard let self, case .snippet(let snippet)? = self.model.nodeById(id) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet.content, forType: .string)
            Toast.show("Copied", in: self.main.view.window, duration: Toast.briefDuration)
        }
        railView.onStowTab = { [weak self] in self?.main.stowFrontTab() }
        railView.onReorder = { [weak self] id, index in self?.model.moveNode(id: id, toParentId: nil, index: index) }
        railView.onMoveToWorkspace = { [weak self] id, workspaceId in self?.model.moveNodeToWorkspace(id: id, workspaceId: workspaceId) }
        railView.onSettings = { [weak self] in self?.main.toggleAppSheet() }
        railView.onNodeMenu = { [weak self] node, cell in
            guard let self, let menu = self.main.nodeMenu(for: node) else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: cell.bounds.width - 4, y: cell.isFlipped ? 0 : cell.bounds.height), in: cell)
        }
        railView.onEditSnippet = { [weak self] id, anchor in self?.main.showSnippetEditor(id, from: anchor) }
        railView.onSetDueDate = { [weak self] id, anchor in self?.main.showDatePickerForTask(id, from: anchor) }
        railView.onNewTask = { [weak self] in self?.main.createTaskInRail(parentId: nil) }
        railView.onDropText = { [weak self] text, index in self?.main.addDroppedText(text, parentId: nil, index: index) }
    }
}
