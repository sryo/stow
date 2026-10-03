import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, WindowAttachmentServiceDelegate, GlobalHotkeyServiceDelegate {
    public override init() {
        super.init()
    }
    private var window: NSWindow?
    private var mainViewController: MainViewController?
    private var alwaysOnTopMenuItem: NSMenuItem?

    // Attachment state
    private var isAttachmentMode: Bool = false
    private var lastManualFrame: NSRect?
    private var isUserHidden: Bool = false

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
        window.minSize = NSSize(width: 280, height: 420)
        window.maxSize = NSSize(width: 520, height: 10000) // Unlimited height for attachment mode
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentViewController = mainViewController
        let restoredFrame = applySavedWindowFrame(to: window)
        if !restoredFrame {
            window.center()
        }
        ensureWindowVisible(window)
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        self.window = window
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
    private static func makeDataStore() -> DataStore {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["STOW_DATA_DIR"], !path.isEmpty {
            return DataStore(baseDirectory: URL(fileURLWithPath: path, isDirectory: true))
        }
        #endif
        return DataStore()
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

        let clampedWidth = min(max(savedFrame.width, window.minSize.width), window.maxSize.width)
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
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Settings…", action: #selector(openPreferences), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Stow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New Workspace…", action: #selector(newWorkspace), keyEquivalent: "n")
        let newFolderItem = NSMenuItem(title: "New Folder…", action: #selector(newFolder), keyEquivalent: "N")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newFolderItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        let findItem = NSMenuItem(title: "Find…", action: #selector(focusSearch), keyEquivalent: "f")
        findItem.target = self
        editMenu.addItem(findItem)
        let jumpItem = NSMenuItem(title: "Jump to Item", action: #selector(toggleJumpMode), keyEquivalent: "j")
        jumpItem.target = self
        editMenu.addItem(jumpItem)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        NSApplication.shared.windowsMenu = windowMenu
        let showWindowItem = NSMenuItem(title: "Show Stow", action: #selector(showMainWindow), keyEquivalent: "")
        showWindowItem.target = self
        windowMenu.addItem(showWindowItem)
        let alwaysOnTopItem = NSMenuItem(title: "Always on top", action: #selector(toggleAlwaysOnTop), keyEquivalent: "t")
        alwaysOnTopItem.keyEquivalentModifierMask = [.command, .option]
        windowMenu.addItem(alwaysOnTopItem)
        alwaysOnTopMenuItem = alwaysOnTopItem
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        for i in 1...9 {
            let item = NSMenuItem(title: "Workspace \(i)", action: #selector(switchToWorkspaceByTag(_:)), keyEquivalent: "\(i)")
            item.tag = i
            item.target = self
            windowMenu.addItem(item)
        }

        NSApplication.shared.mainMenu = mainMenu
    }

    private func applyAlwaysOnTopFromDefaults() {
        let enabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled)
        alwaysOnTopMenuItem?.state = enabled ? .on : .off
        window?.level = enabled ? .floating : .normal
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    @objc private func showMainWindow() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleAlwaysOnTop() {
        let enabled = !(UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled))

        // If enabling always on top, disable attachment first
        if enabled && isAttachmentMode {
            // Save current frame before disabling attachment
            if let window = window {
                lastManualFrame = window.frame
            }

            WindowAttachmentService.shared.disable()
            isAttachmentMode = false
            UserDefaults.standard.set(false, forKey: UserDefaultsKeys.sidebarAttachmentEnabled)
            updateWindowConstraints()
        }

        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.alwaysOnTopEnabled)
        alwaysOnTopMenuItem?.state = enabled ? .on : .off
        window?.level = enabled ? .floating : .normal
    }

    @objc private func openPreferences() {
        // Select the settings tab in the main window instead of opening a separate preferences window
        guard let mainVC = mainViewController else { return }
        mainVC.model.selectSettings()
        showMainWindow()
    }

    @objc private func newWorkspace() {
        mainViewController?.promptCreateWorkspace()
    }

    @objc private func newFolder() {
        mainViewController?.createFolderAndBeginRename(parentId: nil)
    }

    @objc private func focusSearch() {
        showMainWindow()
        mainViewController?.focusSearch()
    }

    @objc private func toggleJumpMode() {
        mainViewController?.toggleJumpMode()
    }

    @objc private func switchToWorkspaceByTag(_ sender: NSMenuItem) {
        mainViewController?.switchToWorkspace(atIndex: sender.tag - 1)
    }

    // MARK: - Menu Validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(switchToWorkspaceByTag(_:)) {
            let index = menuItem.tag - 1
            return index >= 0 && index < (mainViewController?.model.workspaces.count ?? 0)
        }
        return true
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        GlobalHotkeyService.shared.delegate = self

        if let shortcut = KeyboardShortcut.load() {
            GlobalHotkeyService.shared.register(shortcut: shortcut)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutChanged),
            name: .toggleSidebarShortcutChanged,
            object: nil
        )
    }

    @objc private func handleShortcutChanged() {
        if let shortcut = KeyboardShortcut.load() {
            GlobalHotkeyService.shared.register(shortcut: shortcut)
        } else {
            GlobalHotkeyService.shared.unregister()
        }
    }

    func hotkeyServiceDidTrigger(_ service: GlobalHotkeyService) {
        guard let window = window else { return }

        if isUserHidden || !window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            isUserHidden = false

            if isAttachmentMode {
                WindowAttachmentService.shared.forceUpdate()
            }
        } else {
            window.orderOut(nil)
            isUserHidden = true
        }
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
        guard url.scheme == "stow", url.host == "import" else { return }
        guard let fragment = url.fragment, !fragment.isEmpty else { return }
        guard let model = mainViewController?.model else { return }

        do {
            let workspaceId = try model.importWorkspaceFromShareURL(fragment: fragment)
            model.selectWorkspace(id: workspaceId)
            showMainWindow()

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

        guard let browserBundleId = BrowserManager.resolveDefaultBrowserBundleId() else {
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
            window.minSize = NSSize(width: 280, height: 100)
            window.maxSize = NSSize(width: 520, height: 10000)
            window.isMovable = false
            window.isMovableByWindowBackground = false
        } else {
            // Manual mode: restore original constraints, enable movement
            window.minSize = NSSize(width: 280, height: 420)
            window.maxSize = NSSize(width: 520, height: 10000)
            window.isMovable = true
            window.isMovableByWindowBackground = true

            // Restore last manual frame if available
            if let lastFrame = lastManualFrame {
                window.setFrame(lastFrame, display: true, animate: false)
            }
        }
    }

    private func observeBrowserChanges() {
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

        alwaysOnTopMenuItem?.state = enabled ? .on : .off
        window?.level = enabled ? .floating : .normal

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
            guard let browserBundleId = BrowserManager.resolveDefaultBrowserBundleId() else {
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
              let browserBundleId = BrowserManager.resolveDefaultBrowserBundleId() else {
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
        guard !isUserHidden else { return }
        window?.orderFront(nil)
    }
}
