//
//  SettingsContentViewController.swift
//  Stow
//

import AppKit

/// The Settings page at list and sidebar widths: app settings only. The app sheet's
/// Window, Keyboard and Appearance groups (the same AppSheetView the rail's gear and the
/// Tabline's gear show in a flyout, here in its page style), and a footer with the iCloud
/// line, Import… and the version. Workspaces are edited where they show, with a
/// right-click; in the rail, Settings is the gear's sheet.
///
/// Layout is done with frames, top to bottom, so nothing here imposes a minimum width
/// on the container.
@MainActor
final class SettingsContentViewController: NSViewController {

    // MARK: Model

    weak var appModel: AppModel? {
        didSet { reloadWorkspaces() }
    }

    /// Called by MainViewController when workspaces change: the page colour previews follow
    /// the workspace you came from.
    func notifyWorkspacesChanged() {
        reloadWorkspaces()
    }

    // MARK: Views

    private let scrollView = NSScrollView()
    private let pageView = RailFlippedView()
    let sheet = AppSheetView(style: .page)
    private let footer = AppSheetFooterView(showsVersion: true)
    private var keyViewLoopScheduled = false

    // MARK: Lifecycle

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupScrollView()
        pageView.addSubview(sheet)
        sheet.onHeightChange = { [weak self] in self?.relayout() }
        sheet.onShowAllShortcuts = { [weak self] link in self?.toggleAllShortcuts(from: link) }
        footer.onImport = { NotificationCenter.default.post(name: .stowShowImport, object: nil) }
        view.addSubview(footer)
        reloadWorkspaces()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(applicationDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        sheet.refresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        closeFlyouts()
    }

    /// Closes All shortcuts; the main window calls it when the page hides.
    func closeFlyouts() {
        flyouts.closeAll()
    }

    // MARK: All shortcuts

    private let flyouts = FlyoutController()
    private let shortcutsPanel = FlyoutPanel()

    /// "All shortcuts…" opens the same flyout as in the rail, beside the window.
    private func toggleAllShortcuts(from link: NSView) {
        guard let window = view.window else { return }
        let anchor = window.convertToScreen(link.convert(link.bounds, to: nil))
        flyouts.toggle(id: "allShortcuts") {
            let list = AllShortcutsView()
            flyouts.show(shortcutsPanel, id: "allShortcuts", content: list, size: list.preferredSize, anchor: anchor,
                         edge: .beside(column: window.frame), topInset: 24, parent: window)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        relayout()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Setup

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = pageView
        scrollView.contentView.postsBoundsChangedNotifications = true
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.footerHeight),
        ])
    }

    private static let footerHeight: CGFloat = AppSheetFooterView.height + 6

    // MARK: Layout

    /// The page reads as one column: past this width it stops growing and centres, so
    /// counts stay next to names and segmented controls keep their size.
    static let maxContentWidth: CGFloat = 420

    /// The column's horizontal extent in a page `width` wide.
    static func contentColumn(width: CGFloat) -> ClosedRange<CGFloat> {
        let column = min(width, maxContentWidth)
        let x = floor((width - column) / 2)
        return x...(x + column)
    }

    /// The sheet's groups, top to bottom; the footer stays pinned below.
    private func relayout() {
        guard isViewLoaded else { return }
        let pageWidth = scrollView.contentSize.width
        guard pageWidth > 0 else { return }
        let column = Self.contentColumn(width: pageWidth)
        let x = column.lowerBound
        let width = column.upperBound - column.lowerBound
        let pad = SettingsMetrics.rowPadding
        var y: CGFloat = 4
        let sheetHeight = sheet.preferredHeight(forWidth: width)
        sheet.frame = NSRect(x: x, y: y, width: width, height: sheetHeight)
        y += sheetHeight + 12
        pageView.frame = NSRect(x: 0, y: 0, width: pageWidth, height: y)
        let footerColumn = Self.contentColumn(width: view.bounds.width)
        footer.frame = NSRect(x: footerColumn.lowerBound + pad, y: view.isFlipped ? view.bounds.height - Self.footerHeight : 0,
                              width: footerColumn.upperBound - footerColumn.lowerBound - pad * 2, height: AppSheetFooterView.height)
        scheduleKeyViewLoop()
    }

    private func scheduleKeyViewLoop() {
        guard !keyViewLoopScheduled else { return }
        keyViewLoopScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keyViewLoopScheduled = false
            guard let window = self.view.window, !self.view.isHiddenOrHasHiddenAncestor else { return }
            window.recalculateKeyViewLoop()
        }
    }

    // MARK: Workspaces

    private func reloadWorkspaces() {
        guard isViewLoaded, appModel != nil else { return }
        sheet.previewColor = lastViewedWorkspace?.colorId ?? .defaultColor()
        relayout()
    }

    private var lastViewedWorkspace: Workspace? {
        guard let appModel else { return nil }
        if let string = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastSelectedWorkspaceId),
           let id = UUID(uuidString: string), let workspace = appModel.workspaces.first(id: id) {
            return workspace
        }
        if let id = appModel.state.selectedWorkspaceId, let workspace = appModel.workspaces.first(id: id) {
            return workspace
        }
        return appModel.workspaces.first
    }

    @objc private func applicationDidBecomeActive() {
        AppPreferences.shared.applyPendingTabline()
        if AppPreferences.shared.applyPendingAttachment() {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "Accessibility granted. Stow is attached to your browser.",
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        sheet.refresh()
    }
}

extension Notification.Name {
    static let stowTintModeChanged = Notification.Name("StowTintModeChanged")
}
