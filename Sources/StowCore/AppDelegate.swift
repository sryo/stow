import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, WindowAttachmentServiceDelegate, GlobalHotkeyServiceDelegate, AppMenuActions {
    public override init() {
        super.init()
    }
    private var window: NSWindow?
    private var mainViewController: MainViewController?

    // Attachment state
    private var isAttachmentMode: Bool = false
    private var lastManualFrame: NSRect?
    /// The window, or the Tabline standing in for it: one on screen at a time.
    private lazy var surface = StowSurface(
        showWindow: { [weak self] in self?.revealWindow() },
        hideWindow: { [weak self] in self?.window?.orderOut(nil) },
        setTablineHidden: { TablineController.shared.setHiddenByUser($0) })
    private var isUserHidden: Bool { surface.isUserHidden }

    // Save failures repeat on every mutation while the disk condition persists;
    // alert once per session and let os.log carry the rest.
    private var hasShownSaveErrorAlert = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenus()
        registerURLHandler()
        ActiveBrowserTracker.shared.start()
        #if DEBUG
        switch ProcessInfo.processInfo.environment["STOW_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        #endif

        let model = AppModel(store: Self.makeDataStore())
        OpensInStore().migrateIfNeeded(workspaces: model.workspaces)
        ImportCoordinator.shared.model = model
        ImportCoordinator.shared.backups = BackupService(baseDirectory: Self.dataDirectory)
        scheduleBackups()
        AppPreferences.shared.startTintSync()
        TablineController.shared.onRunningChanged = { [weak self] in self?.surface.tablineRunningChanged($0) }
        let mainViewController = MainViewController(model: model)
        self.mainViewController = mainViewController

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Stow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = model.currentWorkspace.colorId.backgroundColor
        window.minSize = NSSize(width: ElasticMode.railWidth, height: 420)
        window.maxSize = NSSize(width: 1400, height: 10000) // Elastic: rail up to mosaic; unlimited height for attachment mode
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentViewController = mainViewController
        var restoredFrame = applySavedWindowFrame(to: window)
        #if DEBUG
        // STOW_WINDOW_WIDTH sizes the window at launch, for checking Elastic modes.
        if let width = ProcessInfo.processInfo.environment["STOW_WINDOW_WIDTH"].flatMap(Double.init) {
            restoredFrame = false
            // Window managers tile resizable windows; a fixed-size floating one is left alone.
            // STOW_WINDOW_RESIZABLE keeps it resizable, for dragging between widths.
            if ProcessInfo.processInfo.environment["STOW_WINDOW_RESIZABLE"] == nil {
                window.styleMask.remove(.resizable)
            }
            window.level = .floating
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let env = ProcessInfo.processInfo.environment
                let height = env["STOW_WINDOW_HEIGHT"].flatMap(Double.init) ?? 620
                let x = env["STOW_WINDOW_X"].flatMap(Double.init) ?? 200
                let y = env["STOW_WINDOW_Y"].flatMap(Double.init) ?? 200
                window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            }
        }
        #endif
        if !restoredFrame {
            window.center()
        }
        ensureWindowVisible(window)
        window.delegate = self
        if !surface.tablineRunning {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }

        self.window = window
        ImportCoordinator.shared.window = window
        AppPreferences.shared.attachSide = { [weak self] in self?.currentSideOfBrowser() }
        applyAlwaysOnTopFromDefaults()
        setupAttachmentService()
        setupGlobalHotkey()
        observeBrowserChanges()

        // Initialize iCloud sync
        CloudSyncManager.shared.configure(model: model)
        model.deletionScheduler = { ids in
            for id in ids { CloudSyncManager.shared.scheduleDeletion(for: id) }
        }
        model.onSaveError = { [weak self] error in
            self?.presentSaveError(error)
        }
        NSApp.registerForRemoteNotifications()

        NSApp.activate(ignoringOtherApps: true)
    }

    /// `STOW_DATA_DIR` points debug builds at a scratch data directory, for UI work
    /// against fixtures without touching the real library.
    static var dataDirectory: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["STOW_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Stow", isDirectory: true)
    }

    private static func makeDataStore() -> DataStore {
        DataStore(baseDirectory: dataDirectory)
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        CloudSyncManager.shared.fetchChanges()
    }

    public func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        CloudSyncManager.shared.fetchChanges()
    }

    public func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Sync falls back to the 30-second poll timer; log so the degraded
        // mode is diagnosable instead of silent.
        NSLog("Stow: push registration failed, sync falls back to polling — \(error.localizedDescription)")
    }

    private func presentSaveError(_ error: Error) {
        guard !hasShownSaveErrorAlert else { return }
        hasShownSaveErrorAlert = true
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Stow couldn't save your data"
        alert.informativeText = "Your latest changes are kept in memory but could not be written to disk: \(error.localizedDescription)"
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        guard !isAttachmentMode, let window else { return }
        saveWindowFrame(window)
    }

    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: ElasticMode.snappedWidth(frameSize.width), height: frameSize.height)
    }

    public func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        saveWindowFrame(window)
    }

    private func ensureWindowVisible(_ window: NSWindow) {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        if screenFrame.intersects(window.frame) { return }

        let origin = NSPoint(
            x: screenFrame.midX - window.frame.width / 2,
            y: screenFrame.midY - window.frame.height / 2
        )
        window.setFrameOrigin(origin)
    }

    private func applySavedWindowFrame(to window: NSWindow) -> Bool {
        guard let frameString = UserDefaults.standard.string(forKey: UserDefaultsKeys.mainWindowFrame) else {
            return false
        }
        let savedFrame = NSRectFromString(frameString)
        guard savedFrame.width > 0, savedFrame.height > 0 else { return false }

        let clampedWidth = ElasticMode.snappedWidth(min(max(savedFrame.width, window.minSize.width), window.maxSize.width))
        let clampedHeight = min(max(savedFrame.height, window.minSize.height), window.maxSize.height)
        let restoredFrame = NSRect(x: savedFrame.origin.x, y: savedFrame.origin.y, width: clampedWidth, height: clampedHeight)
        window.setFrame(restoredFrame, display: false)
        return true
    }

    private func saveWindowFrame(_ window: NSWindow) {
        guard !isAttachmentMode else { return }
        let frameString = NSStringFromRect(window.frame)
        UserDefaults.standard.set(frameString, forKey: UserDefaultsKeys.mainWindowFrame)
    }

    private func setupMenus() {
        let main = AppMenus.build(target: nil)
        NSApplication.shared.mainMenu = main
        NSApplication.shared.windowsMenu = main.items.first { $0.submenu?.title == "Window" }?.submenu
    }

    /// On Top floats the window; `STOW_KEEP_FLOATING` keeps a debug test window above
    /// other apps whatever the mode.
    private func applyWindowLevel(onTop: Bool) {
        var floating = onTop
        #if DEBUG
        if ProcessInfo.processInfo.environment["STOW_KEEP_FLOATING"] != nil { floating = true }
        #endif
        window?.level = floating ? .floating : .normal
    }

    private func applyAlwaysOnTopFromDefaults() {
        applyWindowLevel(onTop: UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled))
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        surface.reopen()
        return true
    }

    // MARK: - Menu actions

    @objc public func showMainWindow(_ sender: Any?) {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Window ▸ Window Mode ▸ Floating / On Top / Attached, mapped onto the dock like
    /// the sheet so both stay in step.
    @objc public func setWindowModeFromMenu(_ sender: NSMenuItem) {
        AppPreferences.shared.setWindowMode(AppWindowMode(rawValue: sender.tag) ?? .floating)
    }

    /// ⌥⌘T: On Top ↔ Floating.
    @objc public func toggleAlwaysOnTop(_ sender: Any?) {
        AppPreferences.shared.toggleOnTop()
    }

    /// ⌥⌘L: the Tabline on top, or back to the dock before it.
    @objc public func toggleTabline(_ sender: Any?) {
        AppPreferences.shared.toggleTabline()
    }

    @objc public func openPreferences(_ sender: Any?) {
        // Select the settings tab in the main window instead of opening a separate preferences window
        if surface.tablineRunning { return TablineController.shared.showSettings() }
        guard let mainVC = mainViewController else { return }
        mainVC.toggleSettings()
        showMainWindow(nil)
    }

    @objc public func newWorkspace(_ sender: Any?) {
        mainViewController?.promptCreateWorkspace()
    }

    @objc public func newFolder(_ sender: Any?) {
        mainViewController?.createFolderAndBeginRename(parentId: nil)
    }

    @objc public func focusSearch(_ sender: Any?) {
        showMainWindow(nil)
        mainViewController?.focusSearch()
    }

    @objc public func toggleJumpMode(_ sender: Any?) {
        mainViewController?.toggleJumpMode()
    }

    @objc public func switchToWorkspaceByTag(_ sender: NSMenuItem) {
        mainViewController?.switchToWorkspace(atIndex: sender.tag - 1)
    }

    @objc public func nextWorkspace(_ sender: Any?) { stepWorkspace(1) }
    @objc public func previousWorkspace(_ sender: Any?) { stepWorkspace(-1) }

    private func stepWorkspace(_ step: Int) {
        guard let main = mainViewController else { return }
        let model = main.model
        let current = model.state.isSettingsSelected ? nil : model.workspaces.firstIndex { $0.id == model.currentWorkspace.id }
        guard let index = AppMenus.steppedIndex(current: current, count: model.workspaces.count, step: step) else { return }
        main.switchToWorkspace(atIndex: index)
    }

    @objc public func showImport(_ sender: Any?) {
        showMainWindow(nil)
        ImportCoordinator.shared.showPicker()
    }

    @objc public func exportAll(_ sender: Any?) {
        ImportCoordinator.shared.exportAll()
    }

    @objc public func showDataInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([Self.dataDirectory.appendingPathComponent("data.json")])
    }

    @objc public func restoreFromBackup(_ sender: Any?) {
        showMainWindow(nil)
        ImportCoordinator.shared.showRestore()
    }

    // MARK: - Menu Validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let count = mainViewController?.model.workspaces.count ?? 0
        switch menuItem.action {
        case #selector(switchToWorkspaceByTag(_:)):
            let index = menuItem.tag - 1
            return index >= 0 && index < count
        case #selector(setWindowModeFromMenu(_:)):
            menuItem.state = AppPreferences.shared.windowMode.rawValue == menuItem.tag ? .on : .off
        case #selector(toggleAlwaysOnTop(_:)):
            menuItem.state = AppPreferences.shared.windowMode == .onTop ? .on : .off
        case #selector(toggleTabline(_:)):
            menuItem.state = AppPreferences.shared.tablineEnabled ? .on : .off
        case #selector(nextWorkspace(_:)), #selector(previousWorkspace(_:)):
            return count > 1 || (count == 1 && mainViewController?.model.state.isSettingsSelected == true)
        case #selector(restoreFromBackup(_:)):
            return !BackupService(baseDirectory: Self.dataDirectory).list().isEmpty
        default:
            break
        }
        return true
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        GlobalHotkeyService.shared.delegate = self
        GlobalHotkeyService.shared.apply()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutChanged),
            name: .toggleSidebarShortcutChanged,
            object: nil
        )
    }

    @objc private func handleShortcutChanged() {
        GlobalHotkeyService.shared.apply()
    }

    func hotkeyService(_ service: GlobalHotkeyService, didTrigger action: HotkeyAction) {
        switch action {
        case .toggleStow: toggleStowWindow()
        case .stowFrontTab: mainViewController?.stowFrontTab()
        }
    }

    private func toggleStowWindow() {
        surface.toggle()
    }

    private func revealWindow() {
        WindowRevealer(
            isAttached: { [weak self] in self?.isAttachmentMode ?? false },
            orderFront: { [weak self] in self?.window?.orderFront(nil) },
            makeKeyAndActivate: { [weak self] in
                self?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            },
            placeOnBrowser: { WindowAttachmentService.shared.forceUpdate() }
        ).reveal()
    }

    // MARK: - URL Handling

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        handleIncomingURL(url)
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard ShareService.importFragment(from: url) != nil,
              let model = mainViewController?.model else { return }

        do {
            guard let workspaceId = try model.importSharedLink(url) else { return }
            model.selectWorkspace(id: workspaceId)
            showMainWindow(nil)

            let alert = NSAlert()
            alert.messageText = "Workspace imported"
            alert.informativeText = "The shared workspace has been imported successfully."
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Window Attachment

    private func setupAttachmentService() {
        WindowAttachmentService.shared.delegate = self

        // Check for mutual exclusion with always on top
        let alwaysOnTopEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled)
        if alwaysOnTopEnabled {
            // Don't enable attachment if always on top is enabled
            return
        }

        let attachmentEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled)
        guard attachmentEnabled else { return }

        // Load preferences
        let positionString = UserDefaults.standard.string(forKey: UserDefaultsKeys.sidebarPosition) ?? "right"
        let position: SidebarPosition = positionString == "left" ? .left : .right

        guard let browserBundleId = BrowserManager.attachTargetBundleId() else {
            print("AppDelegate: No browser bundle ID available for attachment")
            return
        }

        // Save current frame before entering attachment mode
        if let window = window {
            lastManualFrame = window.frame
        }

        isAttachmentMode = true
        updateWindowConstraints()

        WindowAttachmentService.shared.enable(browserBundleId: browserBundleId, position: position)
    }

    private func updateWindowConstraints() {
        guard let window = window else { return }

        if isAttachmentMode {
            // In attachment mode: allow unlimited height, disable manual movement
            window.minSize = NSSize(width: ElasticMode.railWidth, height: 100)
            window.maxSize = NSSize(width: 520, height: 10000)
            window.isMovable = false
            window.isMovableByWindowBackground = false
        } else {
            // Manual mode: restore original constraints, enable movement
            window.minSize = NSSize(width: ElasticMode.railWidth, height: 420)
            window.maxSize = NSSize(width: 1400, height: 10000)
            window.isMovable = true
            window.isMovableByWindowBackground = true

            // Restore last manual frame if available
            if let lastFrame = lastManualFrame {
                window.setFrame(lastFrame, display: true, animate: false)
            }
        }
    }

    /// Which side of the attach browser's front window Stow sits on, from the window
    /// list (no Accessibility needed). Both frames are in screen coordinates.
    private func currentSideOfBrowser() -> Int? {
        guard let window, let bundleId = BrowserManager.attachTargetBundleId(),
              let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId })?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let browser = list.first { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0
        }
        guard let bounds = browser?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let browserFrame = NSRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        return AppPreferences.side(of: window.frame, besides: browserFrame)
    }

    /// One silent snapshot of data.json a day, kept 14 days.
    private func scheduleBackups() {
        let backups = BackupService(baseDirectory: Self.dataDirectory)
        backups.backUpIfNeeded()
        backupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            BackupService(baseDirectory: AppDelegate.dataDirectory).backUpIfNeeded()
        }
    }

    private var backupTimer: Timer?

    @objc private func accessibilityDisplayChanged(_ note: Notification) {
        // Increase Contrast changes the page color that's drawn.
        NotificationCenter.default.post(name: .stowTintModeChanged, object: nil)
    }

    @objc private func showImportFromFooter(_ note: Notification) {
        showImport(nil)
    }

    private func observeBrowserChanges() {
        NotificationCenter.default.addObserver(self, selector: #selector(showImportFromFooter(_:)), name: .stowShowImport, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityDisplayChanged(_:)),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBrowserChanged),
            name: .defaultBrowserChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAlwaysOnTopSettingChanged),
            name: .alwaysOnTopSettingChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAttachmentSettingChanged),
            name: .attachmentSettingChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarPositionChanged),
            name: .sidebarPositionChanged,
            object: nil
        )
    }

    @objc private func handleBrowserChanged(_ notification: Notification) {
        guard isAttachmentMode,
              let bundleId = notification.userInfo?["bundleId"] as? String else {
            return
        }

        let positionString = UserDefaults.standard.string(forKey: UserDefaultsKeys.sidebarPosition) ?? "right"
        let position: SidebarPosition = positionString == "left" ? .left : .right

        WindowAttachmentService.shared.disable()
        WindowAttachmentService.shared.enable(browserBundleId: bundleId, position: position)
    }

    @objc private func handleAlwaysOnTopSettingChanged(_ notification: Notification) {
        guard let enabled = notification.userInfo?["enabled"] as? Bool else { return }

        applyWindowLevel(onTop: enabled)

        // If enabling and attachment is active, disable attachment
        if enabled && isAttachmentMode {
            if let window = window {
                lastManualFrame = window.frame
            }
            WindowAttachmentService.shared.disable()
            isAttachmentMode = false
            updateWindowConstraints()
        }
    }

    @objc private func handleAttachmentSettingChanged(_ notification: Notification) {
        guard let enabled = notification.userInfo?["enabled"] as? Bool else { return }

        if enabled {
            // Enable attachment
            guard let browserBundleId = BrowserManager.attachTargetBundleId() else {
                print("AppDelegate: No browser bundle ID available for attachment")
                return
            }

            let positionString = notification.userInfo?["position"] as? String ?? "right"
            let position: SidebarPosition = positionString == "left" ? .left : .right

            if let window = window {
                lastManualFrame = window.frame
            }

            isAttachmentMode = true
            updateWindowConstraints()
            WindowAttachmentService.shared.enable(browserBundleId: browserBundleId, position: position)
        } else {
            // Disable attachment
            WindowAttachmentService.shared.disable()
            isAttachmentMode = false
            updateWindowConstraints()

            // Show window in case it was hidden
            window?.orderFront(nil)
        }
    }

    @objc private func handleSidebarPositionChanged(_ notification: Notification) {
        guard isAttachmentMode,
              let positionString = notification.userInfo?["position"] as? String,
              let browserBundleId = BrowserManager.attachTargetBundleId() else {
            return
        }

        let position: SidebarPosition = positionString == "left" ? .left : .right

        // Re-enable with new position
        WindowAttachmentService.shared.disable()
        WindowAttachmentService.shared.enable(browserBundleId: browserBundleId, position: position)
    }

    // MARK: - WindowAttachmentServiceDelegate

    func attachmentService(_ service: WindowAttachmentService, shouldPositionWindow frame: NSRect, animated: Bool) {
        guard let window = window else { return }

        // Always show window if hidden, even if frame hasn't changed
        if !window.isVisible {
            window.setFrame(frame, display: true, animate: false)
            window.orderFront(nil)
            return
        }

        // Skip if frame hasn't changed and window is already visible
        if window.frame == frame { return }

        // Apply frame with smooth animation
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            })
        } else {
            window.setFrame(frame, display: true, animate: false)
        }

        // Ensure window is visible alongside the browser
        window.orderFront(nil)
    }

    func attachmentServiceShouldHideWindow(_ service: WindowAttachmentService) {
        window?.orderOut(nil)
    }

    func attachmentServiceShouldShowWindow(_ service: WindowAttachmentService) {
        guard !isUserHidden, !surface.tablineRunning else { return }
        window?.orderFront(nil)
    }
}

