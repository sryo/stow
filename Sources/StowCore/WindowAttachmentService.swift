//
//  WindowAttachmentService.swift
//  Stow
//
//  Service for attaching Stow window to browser windows using macOS Accessibility API.
//

import AppKit
@preconcurrency import ApplicationServices

@MainActor
protocol WindowAttachmentServiceDelegate: AnyObject {
    func attachmentService(_ service: WindowAttachmentService, shouldPositionWindow frame: NSRect, animated: Bool)
    func attachmentServiceShouldHideWindow(_ service: WindowAttachmentService)
    func attachmentServiceShouldShowWindow(_ service: WindowAttachmentService)
}

/// What Attached mode does when an app comes to the front.
enum AttachmentActivation {
    enum Response: Equatable {
        /// Sit beside this browser and show.
        case attach(String)
        /// Stay as is (Stow itself came forward from the browser).
        case keep
        case hide
    }

    static func respond(to bundleId: String?, currentBrowser: String?, lastFrontmost: String?,
                        stow: String?, isBrowser: (String) -> Bool) -> Response {
        if let bundleId, bundleId == currentBrowser || isBrowser(bundleId) { return .attach(bundleId) }
        if bundleId == stow { return lastFrontmost == currentBrowser ? .keep : .hide }
        return .hide
    }
}

@MainActor
final class WindowAttachmentService {
    static let shared = WindowAttachmentService()

    weak var delegate: WindowAttachmentServiceDelegate?

    // State tracking
    private var browserApp: NSRunningApplication?
    private var browserWindowElement: AXUIElement?
    private var windowObserver: AXNotificationObserver?
    private var appObserver: AXNotificationObserver?
    private var isEnabled: Bool = false
    private var currentBrowserBundleId: String?
    private var sidebarPosition: SidebarPosition = .right
    private var lastFrontmostBundleId: String?

    // Notification observers
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenChangeObserver: NSObjectProtocol?

    // Debouncing - reduced from 0.05 to 0.016 (~60fps) for smoother tracking
    private var positionUpdateTimer: Timer?
    private let positionDebounceInterval: TimeInterval = 0.016

    // Frame caching to skip redundant updates
    private var lastBrowserFrame: NSRect?
    private var lastStowFrame: NSRect?

    // Screen caching to reduce detection overhead
    private var cachedScreen: NSScreen?
    private var cachedScreenFrame: NSRect?

    // Smooth animation using NSAnimationContext
    private var isAnimating: Bool = false
    private let animationDuration: TimeInterval = 0.12 // 120ms smooth animation

    private init() {}

    // MARK: - Public Interface

    func enable(browserBundleId: String, position: SidebarPosition) {
        guard checkAccessibilityPermissions() else {
            print("WindowAttachmentService: Accessibility permissions not granted")
            requestAccessibilityPermissions()
            return
        }

        print("WindowAttachmentService: Enabling attachment to \(browserBundleId), position: \(position)")

        self.currentBrowserBundleId = browserBundleId
        self.sidebarPosition = position
        self.isEnabled = true

        setupWorkspaceObservers()
        setupScreenChangeObserver()
        attachToBrowser()
    }

    func disable() {
        print("WindowAttachmentService: Disabling attachment")

        isEnabled = false
        cleanupObservers()
        cleanupAppObserver()
        cleanupWorkspaceObservers()
        cleanupScreenChangeObserver()

        browserApp = nil
        browserWindowElement = nil
        currentBrowserBundleId = nil
        lastBrowserFrame = nil
        lastStowFrame = nil
        lastFrontmostBundleId = nil
    }

    func checkAccessibilityPermissions() -> Bool {
        let optionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [optionKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func requestAccessibilityPermissions() {
        let optionKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [optionKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Browser Window Discovery

    private func findFrontmostBrowserWindow(activeApp: NSRunningApplication? = nil) -> AXUIElement? {
        guard let bundleId = currentBrowserBundleId else { return nil }

        let app: NSRunningApplication
        if let activeApp, activeApp.bundleIdentifier == bundleId {
            app = activeApp
        } else {
            guard let found = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) else {
                return nil
            }
            app = found
        }

        guard app.isActive else { return nil }

        let appElement = AXHelper.application(app.processIdentifier)

        // Try focused window first (handles multi-window correctly)
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focusedWindow = focusedRef {
            let element = AXHelper.bounded(focusedWindow as! AXUIElement)
            // Check if window is minimized
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
            if let isMinimized = minimized as? Bool, isMinimized {
                return nil
            }
            return element
        }

        // Fallback to first window in windows list
        var windowList: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowList)
        guard result == .success else { return nil }

        guard let windows = windowList as? [AXUIElement], let firstWindow = windows.first.map(AXHelper.bounded) else {
            return nil
        }

        // Check if window is minimized
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(firstWindow, kAXMinimizedAttribute as CFString, &minimized)
        if let isMinimized = minimized as? Bool, isMinimized {
            return nil
        }

        return firstWindow
    }

    // MARK: - Window Frame Extraction

    private func getWindowFrame(_ windowElement: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let position = positionRef,
              let size = sizeRef else {
            return nil
        }

        var cgPoint = CGPoint.zero
        var cgSize = CGSize.zero

        AXValueGetValue(position as! AXValue, .cgPoint, &cgPoint)
        AXValueGetValue(size as! AXValue, .cgSize, &cgSize)

        // Convert from Accessibility coordinates (top-left origin) to Cocoa coordinates (bottom-left origin)
        if let screen = NSScreen.main {
            let screenHeight = screen.frame.height
            let flippedY = screenHeight - cgPoint.y - cgSize.height
            return NSRect(x: cgPoint.x, y: flippedY, width: cgSize.width, height: cgSize.height)
        }

        return NSRect(origin: cgPoint, size: cgSize)
    }

    // MARK: - Position Calculation

    private func calculateStowFrame(browserFrame: NSRect, stowWidth: CGFloat) -> NSRect? {
        // Check minimum browser width requirement
        let minBrowserWidth: CGFloat = 600
        guard browserFrame.width >= minBrowserWidth else { return nil }

        // Detect which screen contains the browser window
        guard let screen = detectScreen(for: browserFrame) else { return nil }

        let screenFrame = screen.visibleFrame

        // Calculate Stow X position based on sidebar position
        let stowX: CGFloat
        switch sidebarPosition {
        case .left:
            stowX = browserFrame.minX - stowWidth
            // Check if there's enough space on the left
            if stowX < screenFrame.minX { return nil }
        case .right:
            stowX = browserFrame.maxX
            // Check if there's enough space on the right
            if stowX + stowWidth > screenFrame.maxX { return nil }
        }

        // Match browser height exactly
        let stowY = browserFrame.minY
        let stowHeight = browserFrame.height

        return NSRect(x: stowX, y: stowY, width: stowWidth, height: stowHeight)
    }

    private func detectScreen(for frame: NSRect) -> NSScreen? {
        // Use cached screen if the frame is still within the same screen bounds
        if let cached = cachedScreen,
           let cachedBounds = cachedScreenFrame,
           cachedBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
            return cached
        }

        // Recalculate if cache miss
        let screens = NSScreen.screens
        var bestScreen: NSScreen?
        var bestOverlap: CGFloat = 0

        for screen in screens {
            let intersection = frame.intersection(screen.frame)
            let overlap = intersection.width * intersection.height
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestScreen = screen
            }
        }

        let result = bestScreen ?? NSScreen.main
        cachedScreen = result
        cachedScreenFrame = result?.frame

        return result
    }

    // MARK: - Main Update Loop

    private func schedulePositionUpdate() {
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = Timer.scheduledTimer(withTimeInterval: positionDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateStowPosition()
            }
        }
    }

    private func updateStowPosition(forceShow: Bool = false) {
        guard isEnabled else { return }

        // Find the frontmost browser window
        guard let windowElement = findFrontmostBrowserWindow() else {
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Get the browser window frame
        guard let browserFrame = getWindowFrame(windowElement) else {
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Check if frame has changed
        let frameChanged = lastBrowserFrame != browserFrame
        lastBrowserFrame = browserFrame

        // Get current Stow window width (user may have resized it)
        let stowWidth: CGFloat = 340 // Default width, will be updated by delegate if needed

        // Calculate new Stow frame
        guard let newFrame = calculateStowFrame(browserFrame: browserFrame, stowWidth: stowWidth) else {
            // Invalid frame (browser too narrow, not enough space, etc.)
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Check if calculated frame has changed
        let calculatedFrameChanged = lastStowFrame != newFrame
        lastStowFrame = newFrame

        // Only update if frame changed or if we're forcing show (e.g., app switch)
        if frameChanged || calculatedFrameChanged || forceShow {
            // Notify delegate to position window with smooth animation
            delegate?.attachmentService(self, shouldPositionWindow: newFrame, animated: true)
        }
    }

    // MARK: - Browser Attachment

    private func attachToBrowser() {
        guard let bundleId = currentBrowserBundleId else {
            print("WindowAttachmentService: No browser bundle ID configured")
            return
        }

        // Check if browser is running
        guard BrowserManager.isRunning(bundleId: bundleId) else {
            print("WindowAttachmentService: Browser not running")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Check if browser is active (frontmost)
        guard let frontmost = BrowserManager.frontmostApp() else {
            print("WindowAttachmentService: Could not determine frontmost app")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        guard frontmost.bundleIdentifier == bundleId else {
            print("WindowAttachmentService: Browser not active")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Setup app-level observer for focused window changes (handles multi-window)
        observeAppWindowChanges(app: frontmost)

        // Find browser window
        guard let windowElement = findFrontmostBrowserWindow(activeApp: frontmost) else {
            print("WindowAttachmentService: No browser window found")
            delegate?.attachmentServiceShouldHideWindow(self)
            return
        }

        // Check if we're already observing this exact window
        if let existingElement = browserWindowElement,
           CFEqual(existingElement, windowElement) {
            // Same window — check if observers got lost and re-register if needed
            if windowObserver == nil {
                print("WindowAttachmentService: Re-registering observers for existing window")
                browserApp = frontmost
                observeBrowserWindow()
            }
            // Force show in case window was hidden and we're switching to browser
            updateStowPosition(forceShow: true)
            return
        }

        print("WindowAttachmentService: New window detected, setting up observers")

        // Different window - cleanup old observers and setup new ones
        cleanupObservers()
        browserWindowElement = windowElement
        browserApp = frontmost

        // Setup observers for this window
        observeBrowserWindow()

        // Perform initial position update and show window
        updateStowPosition(forceShow: true)
    }

    // MARK: - Public API (continued)

    /// Force an immediate position update (e.g. after hotkey toggle)
    func forceUpdate() {
        guard isEnabled else { return }
        updateStowPosition(forceShow: true)
    }

    // MARK: - App-Level Observer (focused window changes)

    private func observeAppWindowChanges(app: NSRunningApplication) {
        let pid = app.processIdentifier
        // If already observing this PID, skip
        if appObserver?.pid == pid { return }

        // Cleanup previous observer if PID changed
        cleanupAppObserver()

        guard let observer = AXNotificationObserver(pid: pid, handler: { [weak self] _, _ in
            Task { @MainActor in
                self?.attachToBrowser()
            }
        }) else { return }
        observer.add([kAXFocusedWindowChangedNotification], to: AXHelper.application(pid))
        appObserver = observer
    }

    private func cleanupAppObserver() {
        appObserver = nil
    }

    // MARK: - AX Observers

    private func observeBrowserWindow() {
        guard let windowElement = browserWindowElement,
              let app = browserApp else { return }

        guard let observer = AXNotificationObserver(pid: app.processIdentifier, handler: { [weak self] notificationName, _ in
            Task { @MainActor in
                guard let service = self else { return }
                if notificationName == (kAXMovedNotification as String) || notificationName == (kAXResizedNotification as String) {
                    service.schedulePositionUpdate()
                } else if notificationName == (kAXUIElementDestroyedNotification as String) {
                    service.delegate?.attachmentServiceShouldHideWindow(service)
                    service.cleanupObservers()
                }
            }
        }) else { return }

        observer.add([kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification], to: windowElement)
        windowObserver = observer
    }

    private func cleanupObservers() {
        windowObserver = nil
        positionUpdateTimer?.invalidate()
        positionUpdateTimer = nil
        lastBrowserFrame = nil
        lastStowFrame = nil
        cachedScreen = nil
        cachedScreenFrame = nil
        isAnimating = false
    }

    // MARK: - Workspace Observers

    private func setupWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        let activatedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                let bundleId = app.bundleIdentifier
                let stow = Bundle.main.bundleIdentifier

                switch AttachmentActivation.respond(to: bundleId, currentBrowser: self.currentBrowserBundleId,
                                                    lastFrontmost: self.lastFrontmostBundleId, stow: stow,
                                                    isBrowser: BrowserManager.isBrowser) {
                case .attach(let browser):
                    if browser != self.currentBrowserBundleId {
                        self.cleanupObservers()
                        self.cleanupAppObserver()
                        self.browserWindowElement = nil
                        self.lastBrowserFrame = nil
                        self.lastStowFrame = nil
                        self.currentBrowserBundleId = browser
                    }
                    self.lastFrontmostBundleId = bundleId
                    self.attachToBrowser()
                case .keep:
                    return
                case .hide:
                    if bundleId != stow { self.lastFrontmostBundleId = bundleId }
                    self.delegate?.attachmentServiceShouldHideWindow(self)
                }
            }
        }

        let terminatedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                if app.bundleIdentifier == self.currentBrowserBundleId {
                    // Guard: skip cleanup when browser is still running
                    // (handles short-lived URL-opening processes with same bundle ID)
                    guard let bid = self.currentBrowserBundleId, !BrowserManager.isRunning(bundleId: bid) else {
                        return
                    }
                    // Browser quit - hide and cleanup
                    self.delegate?.attachmentServiceShouldHideWindow(self)
                    self.cleanupObservers()
                    self.cleanupAppObserver()
                }
            }
        }

        let launchedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                if app.bundleIdentifier == self.currentBrowserBundleId {
                    // Browser launched - wait for activation
                    // Will be handled by didActivateApplicationNotification
                }
            }
        }

        workspaceObservers = [activatedObserver, terminatedObserver, launchedObserver]
    }

    private func cleanupWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    // MARK: - Screen Change Observer

    private func setupScreenChangeObserver() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Use longer debounce for screen changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateStowPosition()
            }
        }
    }

    private func cleanupScreenChangeObserver() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
    }
}

// MARK: - Shared Accessibility helpers

/// Accessibility calls are synchronous IPC to the target app, so a hung browser would stall
/// the main thread for the system default (about six seconds) on every call. Elements made
/// here give up after `messagingTimeout` instead.
enum AXHelper {
    static let messagingTimeout: Float = 0.2

    static func application(_ pid: pid_t) -> AXUIElement {
        bounded(AXUIElementCreateApplication(pid))
    }

    /// The timeout is per element, so windows read from an app element need it too.
    @discardableResult
    static func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }
}

/// One AXObserver for a process, delivering its notifications to `handler` on the main run loop.
/// The handler runs inside the observer's callback, so it must not release this object
/// synchronously; hop to a later turn first.
@MainActor
final class AXNotificationObserver {
    typealias Handler = @MainActor (_ notification: String, _ element: AXUIElement) -> Void

    let pid: pid_t
    private nonisolated(unsafe) let observer: AXObserver
    private let handler: Handler

    init?(pid: pid_t, handler: @escaping Handler) {
        var created: AXObserver?
        let error = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let name = notification as String
            MainActor.assumeIsolated {
                let target = Unmanaged<AXNotificationObserver>.fromOpaque(refcon).takeUnretainedValue()
                target.handler(name, element)
            }
        }, &created)
        guard error == .success, let created else { return nil }
        self.pid = pid
        self.observer = created
        self.handler = handler
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// True when at least one notification is registered. Fails while Accessibility isn't granted.
    @discardableResult
    func add(_ notifications: [String], to element: AXUIElement) -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for name in notifications {
            let error = AXObserverAddNotification(observer, element, name as CFString, refcon)
            if error == .success || error == .notificationAlreadyRegistered { registered = true }
        }
        return registered
    }

    func remove(_ notifications: [String], from element: AXUIElement) {
        for name in notifications { AXObserverRemoveNotification(observer, element, name as CFString) }
    }
}
