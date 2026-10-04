import AppKit

/// Runs the rail for MainViewController: the workspace rail (RailView) and the Settings
/// rail take over from the page chrome at rail width, swap with each other when the
/// page changes (dots growing into tiles and back), and send their callbacks on.
@MainActor
final class RailCoordinator {
    private unowned let main: MainViewController
    private var model: AppModel { main.model }

    let railView = RailView()
    /// Settings in rail mode: workspace tiles, their editor and the app sheet.
    private(set) lazy var settingsRail = SettingsRailController(model: main.model)
    /// What the rail showed last, to grow dots into tiles (and back) when it changes.
    private enum RailPage { case none, workspace, settings }
    private var railPage: RailPage = .none
    private var isRailMorphing = false
    /// The page content was hidden because the rail took over; leaving the rail shows it again.
    private var contentHiddenByRail = false

    init(main: MainViewController) {
        self.main = main
    }

    /// The rail replaces the workspace chrome (header, search, list, bottom bar) and, like
    /// the mockup, drops the traffic lights. On Settings the rail shows workspace tiles.
    func updateRailVisibility() {
        let rail = main.elasticMode == .rail
        let onSettings = model.state.isSettingsSelected
        let page: RailPage = rail ? (onSettings ? .settings : .workspace) : .none
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
        transitionRail(to: page)
        main.updateOpenTabsPolling()
    }

    /// Swaps the workspace rail and the Settings rail. Between the two, the dots grow
    /// into tiles on the way in and the tiles shrink back into dots on the way out.
    private func transitionRail(to page: RailPage) {
        let previous = railPage
        guard page != previous else {
            guard !isRailMorphing else { return }
            railView.isHidden = page != .workspace
            settingsRail.view.isHidden = page != .settings
            return
        }
        railPage = page
        let animate = RailMotion.animates(windowVisible: main.view.window?.isVisible == true, swiping: main.isSwiping, reduceMotion: RailMotion.reduceMotion)
        let dotCenters = Dictionary(uniqueKeysWithValues: model.workspaces.enumerated().map {
            ($1.id, SettingsRailLayout.dotCenterY(at: $0))
        })
        if page != .settings { settingsRail.willLeave() }

        switch (previous, page) {
        case (.workspace, .settings) where animate:
            settingsRail.didEnter(from: main.lastShownWorkspaceId)
            settingsRail.reload()
            settingsRail.view.resetMorph()
            settingsRail.view.isHidden = false
            settingsRail.view.animateIn(dotCenters: dotCenters)
            settingsRail.view.takeKeyboard()
            isRailMorphing = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                railView.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.isRailMorphing = false
                guard self.railPage == .settings else { return }
                self.railView.isHidden = true
                self.railView.alphaValue = 1
            })
        case (.settings, .workspace) where animate:
            railView.alphaValue = 0
            railView.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.38
                railView.animator().alphaValue = 1
            }
            isRailMorphing = true
            settingsRail.view.animateOut(dotCenters: dotCenters) { [weak self] in
                guard let self else { return }
                self.isRailMorphing = false
                guard self.railPage == .workspace else { return }
                self.settingsRail.view.isHidden = true
                self.settingsRail.view.resetMorph()
            }
        default:
            if page == .settings {
                settingsRail.didEnter(from: main.lastShownWorkspaceId)
                settingsRail.reload()
                settingsRail.view.takeKeyboard()
            }
            settingsRail.view.resetMorph()
            railView.alphaValue = 1
            railView.isHidden = page != .workspace
            settingsRail.view.isHidden = page != .settings
        }
    }

    func reloadRail() {
        guard main.elasticMode == .rail, !model.state.isSettingsSelected else { return }
        let ws = model.currentWorkspace
        railView.configure(
            workspaces: model.workspaces.map { RailView.WorkspaceDot(id: $0.id, name: $0.name, color: $0.colorId.color) },
            selectedId: ws.id,
            colorId: ws.colorId,
            items: ws.items
        )
        FaviconPrefetcher.shared.request(links: ws.items.flattenLinks().filter { !$0.isArchived }, in: ws.id)
    }

    func wireRail() {
        railView.onSelectWorkspace = { [weak self] id in self?.main.selectWorkspaceAndPage(id) }
        railView.onWorkspaceContextMenu = { [weak self] id, dot in
            self?.main.showWorkspaceMenu(for: id, in: dot, at: NSPoint(x: dot.bounds.width - 4, y: dot.isFlipped ? 0 : dot.bounds.height),
                                         editorAnchor: dot.bounds, edge: .besideWindow)
        }
        railView.onOpenLink = { [weak self] link in self?.main.openLink(link) }
        railView.onOpenFolder = { [weak self] folder in self?.main.openLinksInFolder(folder) }
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
        railView.onSettings = { [weak self] in self?.main.enterSettings() }
        railView.onNodeMenu = { [weak self] node, cell in
            guard let self, let menu = self.main.nodeMenu(for: node) else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: cell.bounds.width - 4, y: cell.isFlipped ? 0 : cell.bounds.height), in: cell)
        }
        railView.onEditSnippet = { [weak self] id, anchor in self?.main.showSnippetEditor(id, from: anchor) }
        railView.onSetDueDate = { [weak self] id, anchor in self?.main.showDatePickerForTask(id, from: anchor) }
        railView.onNewTask = { [weak self] in self?.main.createTaskInRail(parentId: nil) }
        railView.onDropText = { [weak self] text, index in self?.main.addDroppedText(text, parentId: nil, index: index) }
        settingsRail.onLeave = { [weak self] id in self?.main.selectWorkspaceAndPage(id) }
        settingsRail.onPreviewColor = { [weak self] colorId in
            self?.main.applyBackgroundColor(for: colorId ?? .settingsBackground)
        }
    }
}
