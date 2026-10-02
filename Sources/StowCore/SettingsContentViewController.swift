//
//  SettingsContentViewController.swift
//  Stow
//

import AppKit

@MainActor
final class SettingsContentViewController: NSViewController {
    // Layout constants
    private let horizontalPadding: CGFloat = 8
    private let sectionSpacing: CGFloat = 12        // Distance between sections
    private let sectionHeaderSpacing: CGFloat = 8   // Distance between section name and content
    private let itemSpacing: CGFloat = 8           // Distance between items within a section
    private let controlLabelSpacing: CGFloat = 4    // Distance between label and control

    // Color constants
    private var sectionHeaderColor: NSColor { SettingsColors.inkSecondary }
    private var regularTextColor: NSColor { SettingsColors.ink }

    // Browser section
    private let browserPopupContainer = NSView()
    private let browserPopup = NSPopUpButton()
    private var browsers: [BrowserInfo] = []

    // Window settings section - custom components
    private let alwaysOnTopToggle = CustomToggle(title: "Always on Top")
    private let attachSidebarToggle = CustomToggle(title: "Attach to Window as Sidebar")
    private let sidebarPositionSelector = SidebarPositionSelector()
    private let tintLabel = NSTextField(labelWithString: "Workspace color")
    private let tintControl = NSSegmentedControl(labels: ["Full", "Subtle", "Off"], trackingMode: .selectOne, target: nil, action: nil)

    // Keyboard shortcuts section
    private let shortcutRecorderView = ShortcutRecorderView()

    // Workspace management section
    private let workspaceCollectionView = WorkspaceContextMenuCollectionView()
    private var workspaceCollectionViewHeightConstraint: NSLayoutConstraint?
    private var contextWorkspaceId: UUID?
    private var customColorTargetWorkspaceId: UUID?
    private var inlineRenameWorkspaceId: UUID?
    private let workspaceDropIndicator = WorkspaceDropIndicatorView()

    // Permissions section
    private let permissionStatusLabel = NSTextField(labelWithString: "")
    private let openSettingsButton = SettingsButton(title: "Open System Settings")
    private let refreshStatusButton = SettingsButton(title: "Refresh Status")

    // Import & Export section
    private let importButton = SettingsButton(title: "Import from Arc Browser")
    private let importStatusLabel = NSTextField(labelWithString: "")

    // Reference to AppModel (will be set from MainViewController)
    weak var appModel: AppModel? {
        didSet {
            reloadWorkspaces()
        }
    }

    // Called by MainViewController when workspaces change
    func notifyWorkspacesChanged() {
        reloadWorkspaces()
    }

    // Scroll view
    private let scrollView = NSScrollView()
    private let contentView = FlippedContentView()

    // Dynamic constraints
    private var separator1ToSelectorConstraint: NSLayoutConstraint?
    private var separator1ToToggleConstraint: NSLayoutConstraint?

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupScrollView()
        setupWorkspaceCollectionView()
        setupUI()
        loadPreferences()
        loadBrowsers()
        updatePermissionStatus()
        reloadWorkspaces()

        // Observe app activation to refresh permission status
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )

        // Observe scroll bounds changes to refresh hover states
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWorkspaceScrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Re-check permissions when view appears
        updatePermissionStatus()
    }

    @objc private func applicationDidBecomeActive() {
        // Re-check permissions when app becomes active (user may have granted in System Settings)
        updatePermissionStatus()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        contentView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func createSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        label.textColor = sectionHeaderColor
        label.translatesAutoresizingMaskIntoConstraints = false

        // Set letter spacing
        if let attrString = label.attributedStringValue.mutableCopy() as? NSMutableAttributedString {
            attrString.addAttribute(.kern, value: 0.5, range: NSRange(location: 0, length: attrString.length))
            label.attributedStringValue = attrString
        }

        return label
    }

    private func createSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        return separator
    }

    private func setupWorkspaceCollectionView() {
        let layout = ListFlowLayout(metrics: ListMetrics())
        workspaceCollectionView.collectionViewLayout = layout
        workspaceCollectionView.translatesAutoresizingMaskIntoConstraints = false
        workspaceCollectionView.dataSource = self
        workspaceCollectionView.delegate = self
        workspaceCollectionView.isSelectable = true  // Changed to true to enable drag and drop
        workspaceCollectionView.allowsMultipleSelection = false
        workspaceCollectionView.backgroundColors = [.clear]
        workspaceCollectionView.settingsController = self

        // Set up context menu handler
        workspaceCollectionView.onRightClick = { [weak self] workspaceId, event in
            self?.showWorkspaceContextMenu(for: workspaceId, at: event)
        }

        // Register the workspace item
        workspaceCollectionView.register(
            WorkspaceCollectionViewItem.self,
            forItemWithIdentifier: NSUserInterfaceItemIdentifier("WorkspaceItem")
        )

        // Register for drag types
        workspaceCollectionView.registerForDraggedTypes([workspacePasteboardType])
        workspaceCollectionView.setDraggingSourceOperationMask(.move, forLocal: true)

        // Setup drop indicator
        workspaceDropIndicator.translatesAutoresizingMaskIntoConstraints = false
        workspaceCollectionView.addSubview(workspaceDropIndicator)
    }

    private func setupUI() {
        // Window Settings Section
        let windowSettingsHeader = createSectionHeader("Window Settings")

        alwaysOnTopToggle.target = self
        alwaysOnTopToggle.action = #selector(alwaysOnTopChanged)
        alwaysOnTopToggle.translatesAutoresizingMaskIntoConstraints = false

        attachSidebarToggle.target = self
        attachSidebarToggle.action = #selector(attachSidebarChanged)
        attachSidebarToggle.translatesAutoresizingMaskIntoConstraints = false

        // Setup position selector
        sidebarPositionSelector.translatesAutoresizingMaskIntoConstraints = false
        sidebarPositionSelector.onPositionChanged = { [weak self] _ in
            self?.sidebarPositionChanged()
        }

        let separator1 = createSeparator()

        // Keyboard Shortcuts Section
        let shortcutsHeader = createSectionHeader("Keyboard shortcuts")

        let shortcutDescriptionLabel = NSTextField(labelWithString: "Toggle Stow")
        shortcutDescriptionLabel.font = NSFont.systemFont(ofSize: 13)
        shortcutDescriptionLabel.textColor = regularTextColor
        shortcutDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false

        shortcutRecorderView.translatesAutoresizingMaskIntoConstraints = false
        shortcutRecorderView.onShortcutChanged = { [weak self] shortcut in
            self?.handleShortcutChanged(shortcut)
        }

        let separatorShortcuts = createSeparator()

        // Workspace Management Section
        let workspaceHeader = createSectionHeader("Manage Workspaces")

        tintLabel.font = NSFont.systemFont(ofSize: 13)
        tintLabel.textColor = regularTextColor
        tintLabel.translatesAutoresizingMaskIntoConstraints = false
        tintControl.translatesAutoresizingMaskIntoConstraints = false
        tintControl.target = self
        tintControl.action = #selector(tintModeChanged)
        tintControl.controlSize = .small
        tintControl.setAccessibilityLabel("Workspace color")
        tintControl.toolTip = "Full fills the window with the workspace color. Subtle tints it lightly. Off keeps it neutral."
        tintControl.selectedSegment = StowTheme.TintMode.allCases.firstIndex(of: StowTheme.preferredTint) ?? 0

        let separator2 = createSeparator()

        // Browser Section
        let browserHeader = createSectionHeader("Browser")

        // Browser popup container with styled background
        browserPopupContainer.translatesAutoresizingMaskIntoConstraints = false
        browserPopupContainer.wantsLayer = true
        browserPopupContainer.layer?.backgroundColor = view.resolvedCGColor(SettingsColors.fill)
        browserPopupContainer.layer?.cornerRadius = 8

        browserPopup.translatesAutoresizingMaskIntoConstraints = false
        browserPopup.target = self
        browserPopup.action = #selector(browserChanged)
        browserPopup.font = NSFont.systemFont(ofSize: 13)
        browserPopup.isBordered = false
        browserPopup.focusRingType = .none

        // Set content tint color for the chevron arrow
        if #available(macOS 14.0, *) {
            browserPopup.contentTintColor = SettingsColors.ink
        }

        let separator3 = createSeparator()

        // Permissions Section
        let permissionsHeader = createSectionHeader("Permissions")

        permissionStatusLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        permissionStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        openSettingsButton.target = self
        openSettingsButton.action = #selector(openAccessibilitySettings)
        openSettingsButton.translatesAutoresizingMaskIntoConstraints = false

        refreshStatusButton.target = self
        refreshStatusButton.action = #selector(refreshPermissionStatus)
        refreshStatusButton.translatesAutoresizingMaskIntoConstraints = false

        let separator4 = createSeparator()

        // Import & Export Section
        let importHeader = createSectionHeader("Import & Export")

        importButton.target = self
        importButton.action = #selector(importFromArc)
        importButton.translatesAutoresizingMaskIntoConstraints = false

        importStatusLabel.font = NSFont.systemFont(ofSize: 11)
        importStatusLabel.textColor = SettingsColors.inkSecondary
        importStatusLabel.maximumNumberOfLines = 0
        importStatusLabel.lineBreakMode = .byWordWrapping
        importStatusLabel.alignment = .center
        importStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        importStatusLabel.isHidden = true
        importStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Add all subviews to contentView
        contentView.addSubview(windowSettingsHeader)
        contentView.addSubview(alwaysOnTopToggle)
        contentView.addSubview(attachSidebarToggle)
        contentView.addSubview(sidebarPositionSelector)
        contentView.addSubview(separator1)
        contentView.addSubview(shortcutsHeader)
        contentView.addSubview(shortcutDescriptionLabel)
        contentView.addSubview(shortcutRecorderView)
        contentView.addSubview(separatorShortcuts)
        contentView.addSubview(workspaceHeader)
        contentView.addSubview(tintLabel)
        contentView.addSubview(tintControl)
        contentView.addSubview(workspaceCollectionView)
        contentView.addSubview(separator2)
        contentView.addSubview(browserHeader)
        contentView.addSubview(browserPopupContainer)
        browserPopupContainer.addSubview(browserPopup)
        contentView.addSubview(separator3)
        contentView.addSubview(permissionsHeader)
        contentView.addSubview(permissionStatusLabel)
        contentView.addSubview(openSettingsButton)
        contentView.addSubview(refreshStatusButton)
        contentView.addSubview(separator4)
        contentView.addSubview(importHeader)
        contentView.addSubview(importButton)
        contentView.addSubview(importStatusLabel)

        // Layout constraints
        NSLayoutConstraint.activate([
            // Content view width should match scroll view width
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            // Window Settings Header
            windowSettingsHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            windowSettingsHeader.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),

            // Always on Top Toggle
            alwaysOnTopToggle.leadingAnchor.constraint(equalTo: windowSettingsHeader.leadingAnchor),
            alwaysOnTopToggle.topAnchor.constraint(equalTo: windowSettingsHeader.bottomAnchor, constant: sectionHeaderSpacing),
            alwaysOnTopToggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            alwaysOnTopToggle.heightAnchor.constraint(equalToConstant: 28),

            // Attach Sidebar Toggle
            attachSidebarToggle.leadingAnchor.constraint(equalTo: alwaysOnTopToggle.leadingAnchor),
            attachSidebarToggle.topAnchor.constraint(equalTo: alwaysOnTopToggle.bottomAnchor, constant: itemSpacing),
            attachSidebarToggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            attachSidebarToggle.heightAnchor.constraint(equalToConstant: 28),

            // Position selector buttons (directly below toggle)
            sidebarPositionSelector.leadingAnchor.constraint(equalTo: attachSidebarToggle.leadingAnchor),
            sidebarPositionSelector.topAnchor.constraint(equalTo: attachSidebarToggle.bottomAnchor, constant: itemSpacing),
            sidebarPositionSelector.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),

            // Separator 1
            separator1.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            separator1.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            separator1.heightAnchor.constraint(equalToConstant: 1),

            // Keyboard Shortcuts Header
            shortcutsHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            shortcutsHeader.topAnchor.constraint(equalTo: separator1.bottomAnchor, constant: sectionSpacing),

            // Shortcut description label
            shortcutDescriptionLabel.leadingAnchor.constraint(equalTo: shortcutsHeader.leadingAnchor),
            shortcutDescriptionLabel.topAnchor.constraint(equalTo: shortcutsHeader.bottomAnchor, constant: sectionHeaderSpacing),

            // Shortcut recorder view
            shortcutRecorderView.leadingAnchor.constraint(equalTo: shortcutsHeader.leadingAnchor),
            shortcutRecorderView.topAnchor.constraint(equalTo: shortcutDescriptionLabel.bottomAnchor, constant: controlLabelSpacing),
            shortcutRecorderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),

            // Separator after shortcuts
            separatorShortcuts.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            separatorShortcuts.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            separatorShortcuts.topAnchor.constraint(equalTo: shortcutRecorderView.bottomAnchor, constant: sectionSpacing),
            separatorShortcuts.heightAnchor.constraint(equalToConstant: 1),

            // Workspace Management Header
            workspaceHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            workspaceHeader.topAnchor.constraint(equalTo: separatorShortcuts.bottomAnchor, constant: sectionSpacing),

                // Workspace Collection View - full width without horizontal padding
            workspaceCollectionView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tintLabel.leadingAnchor.constraint(equalTo: workspaceHeader.leadingAnchor),
            tintLabel.centerYAnchor.constraint(equalTo: tintControl.centerYAnchor),
            tintControl.topAnchor.constraint(equalTo: workspaceHeader.bottomAnchor, constant: sectionHeaderSpacing),
            tintControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            tintControl.leadingAnchor.constraint(greaterThanOrEqualTo: tintLabel.trailingAnchor, constant: 8),

            workspaceCollectionView.topAnchor.constraint(equalTo: tintControl.bottomAnchor, constant: sectionHeaderSpacing),
            workspaceCollectionView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            // Separator 2
            separator2.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            separator2.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            separator2.topAnchor.constraint(equalTo: workspaceCollectionView.bottomAnchor, constant: sectionSpacing),
            separator2.heightAnchor.constraint(equalToConstant: 1),

            // Browser Header
            browserHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            browserHeader.topAnchor.constraint(equalTo: separator2.bottomAnchor, constant: sectionSpacing),

            // Browser Popup Container (directly below header)
            browserPopupContainer.leadingAnchor.constraint(equalTo: browserHeader.leadingAnchor),
            browserPopupContainer.topAnchor.constraint(equalTo: browserHeader.bottomAnchor, constant: sectionHeaderSpacing),
            browserPopupContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            browserPopupContainer.heightAnchor.constraint(equalToConstant: 36),

            // Browser Popup inside container
            browserPopup.leadingAnchor.constraint(equalTo: browserPopupContainer.leadingAnchor, constant: 12),
            browserPopup.trailingAnchor.constraint(equalTo: browserPopupContainer.trailingAnchor, constant: -12),
            browserPopup.centerYAnchor.constraint(equalTo: browserPopupContainer.centerYAnchor),

            // Separator 3
            separator3.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            separator3.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            separator3.topAnchor.constraint(equalTo: browserPopupContainer.bottomAnchor, constant: sectionSpacing),
            separator3.heightAnchor.constraint(equalToConstant: 1),

            // Permissions Header
            permissionsHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            permissionsHeader.topAnchor.constraint(equalTo: separator3.bottomAnchor, constant: sectionSpacing),

            // Permission Status Label
            permissionStatusLabel.leadingAnchor.constraint(equalTo: permissionsHeader.leadingAnchor),
            permissionStatusLabel.topAnchor.constraint(equalTo: permissionsHeader.bottomAnchor, constant: sectionHeaderSpacing),

            // Refresh Status Button (below status label)
            refreshStatusButton.leadingAnchor.constraint(equalTo: permissionStatusLabel.leadingAnchor),
            refreshStatusButton.topAnchor.constraint(equalTo: permissionStatusLabel.bottomAnchor, constant: itemSpacing),
            refreshStatusButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            refreshStatusButton.heightAnchor.constraint(equalToConstant: 36),

            // Open Settings Button (below refresh button)
            openSettingsButton.leadingAnchor.constraint(equalTo: refreshStatusButton.leadingAnchor),
            openSettingsButton.topAnchor.constraint(equalTo: refreshStatusButton.bottomAnchor, constant: itemSpacing),
            openSettingsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            openSettingsButton.heightAnchor.constraint(equalToConstant: 36),

            // Separator 4
            separator4.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            separator4.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            separator4.topAnchor.constraint(equalTo: refreshStatusButton.bottomAnchor, constant: sectionSpacing),
            separator4.heightAnchor.constraint(equalToConstant: 1),

            // Import & Export Header
            importHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            importHeader.topAnchor.constraint(equalTo: separator4.bottomAnchor, constant: sectionSpacing),

            // Import Button (below header)
            importButton.leadingAnchor.constraint(equalTo: importHeader.leadingAnchor),
            importButton.topAnchor.constraint(equalTo: importHeader.bottomAnchor, constant: sectionHeaderSpacing),
            importButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),
            importButton.heightAnchor.constraint(equalToConstant: 36),

            // Import Status Label (below import button)
            importStatusLabel.leadingAnchor.constraint(equalTo: importButton.leadingAnchor),
            importStatusLabel.topAnchor.constraint(equalTo: importButton.bottomAnchor, constant: itemSpacing),
            importStatusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -horizontalPadding),

            // Bottom constraint to define content height - use greaterThanOrEqualTo to allow content to be anchored at top
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: importStatusLabel.bottomAnchor, constant: 24),
        ])

        // Setup dynamic constraints for separator1
        separator1ToSelectorConstraint = separator1.topAnchor.constraint(equalTo: sidebarPositionSelector.bottomAnchor, constant: sectionSpacing)
        separator1ToToggleConstraint = separator1.topAnchor.constraint(equalTo: attachSidebarToggle.bottomAnchor, constant: sectionSpacing)

        // Activate the appropriate constraint based on initial state
        separator1ToSelectorConstraint?.isActive = true

        // Setup workspace collection view height constraint (will be updated dynamically)
        workspaceCollectionViewHeightConstraint = workspaceCollectionView.heightAnchor.constraint(equalToConstant: 0)
        workspaceCollectionViewHeightConstraint?.isActive = true
    }

    @objc private func tintModeChanged() {
        let modes = StowTheme.TintMode.allCases
        guard modes.indices.contains(tintControl.selectedSegment) else { return }
        StowTheme.preferredTint = modes[tintControl.selectedSegment]
        NotificationCenter.default.post(name: .stowTintModeChanged, object: nil)
    }

    private func loadPreferences() {
        // Load Always on Top state
        let alwaysOnTopEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.alwaysOnTopEnabled)
        alwaysOnTopToggle.isOn = alwaysOnTopEnabled

        // Load Attach to Sidebar state
        let attachmentEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.sidebarAttachmentEnabled)
        attachSidebarToggle.isOn = attachmentEnabled

        // Load sidebar position
        let positionString = UserDefaults.standard.string(forKey: UserDefaultsKeys.sidebarPosition) ?? "right"
        sidebarPositionSelector.selectedPosition = positionString

        // Apply mutual exclusion and enable states
        updateControlStates()
    }

    private func loadBrowsers() {
        browsers = BrowserManager.installedBrowsers()
        browserPopup.removeAllItems()
        if browserPopup.menu == nil {
            browserPopup.menu = NSMenu()
        }

        for browser in browsers {
            let item = NSMenuItem(title: browser.name, action: nil, keyEquivalent: "")
            item.representedObject = browser.bundleId
            if let icon = browser.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            browserPopup.menu?.addItem(item)
        }

        let defaultId = BrowserManager.resolveDefaultBrowserBundleId()
        if let defaultId, let index = browsers.firstIndex(where: { $0.bundleId == defaultId }) {
            browserPopup.selectItem(at: index)
        } else if !browsers.isEmpty {
            browserPopup.selectItem(at: 0)
            UserDefaults.standard.set(browsers[0].bundleId, forKey: UserDefaultsKeys.defaultBrowserBundleId)
        }

        // Update the title color after selection
        updateBrowserPopupAppearance()
    }

    private func updateBrowserPopupAppearance() {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: regularTextColor,
            .font: NSFont.systemFont(ofSize: 13)
        ]

        if let title = browserPopup.titleOfSelectedItem {
            browserPopup.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        }
    }

    private func updatePermissionStatus() {
        let hasPermission = WindowAttachmentService.shared.checkAccessibilityPermissions()

        if hasPermission {
            permissionStatusLabel.stringValue = "Accessibility: ✓ granted"
            // Use a darker green for better readability
            permissionStatusLabel.textColor = SettingsColors.success
            openSettingsButton.isHidden = true
        } else {
            permissionStatusLabel.stringValue = "Accessibility: ✗ not granted"
            // Use a darker red for better readability
            permissionStatusLabel.textColor = SettingsColors.danger
            openSettingsButton.isHidden = false
        }
    }

    private func updateControlStates() {
        let alwaysOnTopEnabled = alwaysOnTopToggle.isOn
        let attachmentEnabled = attachSidebarToggle.isOn

        // Determine if sidebar position should be visible
        let shouldShowSidebarPosition = !alwaysOnTopEnabled && attachmentEnabled

        // Mutual exclusion
        if alwaysOnTopEnabled {
            attachSidebarToggle.isEnabled = false
        } else {
            attachSidebarToggle.isEnabled = true
        }

        if attachmentEnabled {
            alwaysOnTopToggle.isEnabled = false
        } else {
            alwaysOnTopToggle.isEnabled = true
        }

        // Update visibility and layout constraints
        sidebarPositionSelector.isHidden = !shouldShowSidebarPosition

        // Switch constraints based on visibility
        if shouldShowSidebarPosition {
            separator1ToToggleConstraint?.isActive = false
            separator1ToSelectorConstraint?.isActive = true
        } else {
            separator1ToSelectorConstraint?.isActive = false
            separator1ToToggleConstraint?.isActive = true
        }
    }

    // MARK: - Actions

    @objc private func alwaysOnTopChanged() {
        let enabled = alwaysOnTopToggle.isOn

        // If enabling, disable attachment first
        if enabled && attachSidebarToggle.isOn {
            attachSidebarToggle.isOn = false
            UserDefaults.standard.set(false, forKey: UserDefaultsKeys.sidebarAttachmentEnabled)

            // Notify to disable attachment
            NotificationCenter.default.post(name: .attachmentSettingChanged, object: nil, userInfo: ["enabled": false])
        }

        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.alwaysOnTopEnabled)

        // Notify to apply always on top
        NotificationCenter.default.post(name: .alwaysOnTopSettingChanged, object: nil, userInfo: ["enabled": enabled])

        updateControlStates()
    }

    @objc private func attachSidebarChanged() {
        let enabled = attachSidebarToggle.isOn

        // Check permissions
        if enabled && !WindowAttachmentService.shared.checkAccessibilityPermissions() {
            let alert = NSAlert()
            alert.messageText = "Accessibility access required"
            alert.informativeText = "Stow needs Accessibility access to attach to browser windows. You can grant this in System Settings."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()

            attachSidebarToggle.isOn = false
            return
        }

        // If enabling, disable always on top first
        if enabled && alwaysOnTopToggle.isOn {
            alwaysOnTopToggle.isOn = false
            UserDefaults.standard.set(false, forKey: UserDefaultsKeys.alwaysOnTopEnabled)

            // Notify to disable always on top
            NotificationCenter.default.post(name: .alwaysOnTopSettingChanged, object: nil, userInfo: ["enabled": false])
        }

        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.sidebarAttachmentEnabled)

        // Get current position
        let position = sidebarPositionSelector.selectedPosition ?? "right"

        // Notify to enable/disable attachment
        NotificationCenter.default.post(
            name: .attachmentSettingChanged,
            object: nil,
            userInfo: ["enabled": enabled, "position": position]
        )

        updateControlStates()
    }

    @objc private func sidebarPositionChanged() {
        guard let position = sidebarPositionSelector.selectedPosition else { return }

        UserDefaults.standard.set(position, forKey: UserDefaultsKeys.sidebarPosition)

        // If attachment is currently enabled, notify to update position
        if attachSidebarToggle.isOn {
            NotificationCenter.default.post(
                name: .sidebarPositionChanged,
                object: nil,
                userInfo: ["position": position]
            )
        }
    }

    @objc private func browserChanged() {
        if let bundleId = browserPopup.selectedItem?.representedObject as? String {
            UserDefaults.standard.set(bundleId, forKey: UserDefaultsKeys.defaultBrowserBundleId)

            // Update appearance after change
            updateBrowserPopupAppearance()

            // Notify about browser change
            NotificationCenter.default.post(
                name: .defaultBrowserChanged,
                object: nil,
                userInfo: ["bundleId": bundleId]
            )
        }
    }

    @objc private func openAccessibilitySettings() {
        WindowAttachmentService.shared.requestAccessibilityPermissions()

        let alert = NSAlert()
        alert.messageText = "Grant Accessibility Access"
        alert.informativeText = "Grant Stow access in System Settings > Privacy & Security > Accessibility, then come back here."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func refreshPermissionStatus() {
        updatePermissionStatus()
    }

    private func handleShortcutChanged(_ shortcut: KeyboardShortcut?) {
        NotificationCenter.default.post(name: .toggleSidebarShortcutChanged, object: nil)
    }

    @objc private func importFromArc() {
        // Construct default Arc path
        let arcPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Arc/StorableSidebar.json")

        // Check if file exists
        guard FileManager.default.fileExists(atPath: arcPath.path) else {
            showImportStatus("Could not find Arc bookmarks. Make sure Arc is installed and has saved bookmarks.", isError: true)
            return
        }

        // Import directly
        Task { @MainActor [weak self] in
            await self?.handleArcImport(fileURL: arcPath)
        }
    }

    private func handleArcImport(fileURL: URL) async {
        // Show loading state
        importButton.setLoading(true)
        showImportStatus("Importing from Arc…", isError: false)

        // Perform import
        let result = await ArcImportService.shared.importFromArc(fileURL: fileURL)

        // Hide loading state
        importButton.setLoading(false)

        switch result {
        case .success(let importResult):
            // Apply to AppModel
            applyImport(importResult)

            // Show success message
            let message = "Imported \(importResult.workspacesCreated) workspaces, \(importResult.linksImported) links, and \(importResult.foldersImported) folders."
            showImportStatus(message, isError: false)

            // Hide message after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.hideImportStatus()
            }

        case .failure(let error):
            showImportStatus(error.localizedDescription, isError: true)
        }
    }

    private func applyImport(_ result: ArcImportResult) {
        guard let appModel = appModel else { return }

        // Remember the currently selected workspace
        let previousWorkspaceId = appModel.state.selectedWorkspaceId

        for workspace in result.workspaces {
            // Create the workspace using AppModel's method
            _ = appModel.createWorkspace(name: workspace.name, colorId: workspace.colorId)

            // The workspace is now selected, add all nodes to it
            for node in workspace.nodes {
                addNodeToWorkspace(node, parentId: nil, appModel: appModel)
            }
        }

        // Restore the previously selected workspace
        if let previousWorkspaceId = previousWorkspaceId {
            appModel.selectWorkspace(id: previousWorkspaceId)
        }

        // Reload the workspace list to reflect the newly imported workspaces
        reloadWorkspaces()
    }

    private func addNodeToWorkspace(_ node: Node, parentId: UUID?, appModel: AppModel) {
        switch node {
        case .link(let link):
            appModel.addLink(urlString: link.url, title: link.title, parentId: parentId)
        case .folder(let folder):
            let folderId = appModel.addFolder(name: folder.name, parentId: parentId, isExpanded: false)
            for child in folder.children {
                addNodeToWorkspace(child, parentId: folderId, appModel: appModel)
            }
        case .task(let task):
            appModel.addTask(title: task.title, parentId: parentId)
        case .snippet(let snippet):
            appModel.addSnippet(title: snippet.title, content: snippet.content, language: snippet.language, parentId: parentId)
        }
    }

    private func showImportStatus(_ message: String, isError: Bool) {
        importStatusLabel.stringValue = message
        importStatusLabel.textColor = isError ? SettingsColors.danger : regularTextColor
        importStatusLabel.isHidden = false
    }

    private func hideImportStatus() {
        importStatusLabel.isHidden = true
    }

    // MARK: - Workspace Management

    private func reloadWorkspaces() {
        guard let appModel = appModel else { return }

        // Update collection view height based on workspace count
        let metrics = ListMetrics()
        let rowCount = appModel.workspaces.count
        let totalHeight = CGFloat(rowCount) * metrics.rowHeight + CGFloat(rowCount - 1) * metrics.verticalGap
        workspaceCollectionViewHeightConstraint?.constant = totalHeight

        // Invalidate layout before reloading to ensure proper sizing
        workspaceCollectionView.collectionViewLayout?.invalidateLayout()

        workspaceCollectionView.reloadData()
    }

    // Animation constants for workspace deletion
    private static let deletionAnimationDuration: TimeInterval = 0.2
    private static let deletionAnimationOffset: CGFloat = 10

    private func handleWorkspaceDelete(id: UUID) {
        guard let appModel = appModel else { return }

        // Check if only one workspace
        if appModel.workspaces.count <= 1 {
            return
        }

        // Skip confirmation for empty workspaces
        let workspace = appModel.workspaces.first(where: { $0.id == id })
        if workspace?.items.isEmpty ?? true {
            animateWorkspaceDeletion(id: id)
            return
        }

        // Show confirmation alert for non-empty workspaces
        let alert = NSAlert()
        alert.messageText = "Delete workspace?"
        alert.informativeText = "This will permanently delete the workspace and all its contents."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")

        // Make Delete button destructive
        if let deleteButton = alert.buttons.last {
            deleteButton.hasDestructiveAction = true
        }

        alert.beginSheetModal(for: view.window!) { response in
            if response == .alertSecondButtonReturn {
                self.animateWorkspaceDeletion(id: id)
            }
        }
    }

    private func animateWorkspaceDeletion(id: UUID) {
        guard let appModel = appModel else { return }
        guard let index = appModel.workspaces.firstIndex(where: { $0.id == id }) else { return }

        let indexPath = IndexPath(item: index, section: 0)

        // Create bitmap snapshot of the item being deleted
        let snapshot = makeWorkspaceDeletionSnapshot(at: indexPath)

        // Delete from model
        appModel.deleteWorkspace(id: id)

        // Update collection view height for the new count
        let metrics = ListMetrics()
        let rowCount = appModel.workspaces.count
        let totalHeight = CGFloat(rowCount) * metrics.rowHeight + CGFloat(max(0, rowCount - 1)) * metrics.verticalGap
        workspaceCollectionViewHeightConstraint?.constant = totalHeight

        // Perform batch update to animate the deletion in the collection view
        workspaceCollectionView.performBatchUpdates({
            self.workspaceCollectionView.deleteItems(at: [indexPath])
        }, completionHandler: { _ in
            // Reload remaining items to update delete button visibility
            self.workspaceCollectionView.reloadData()
        })

        // Animate the snapshot (fade out + slide up)
        animateWorkspaceDeletionSnapshot(snapshot)
    }

    private func makeWorkspaceDeletionSnapshot(at indexPath: IndexPath) -> NSImageView? {
        guard let item = workspaceCollectionView.item(at: indexPath) else { return nil }
        let itemView = item.view
        guard let rep = itemView.bitmapImageRepForCachingDisplay(in: itemView.bounds) else { return nil }
        itemView.cacheDisplay(in: itemView.bounds, to: rep)
        let image = NSImage(size: itemView.bounds.size)
        image.addRepresentation(rep)
        let frame = itemView.convert(itemView.bounds, to: workspaceCollectionView)
        let imageView = NSImageView(frame: frame)
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        workspaceCollectionView.addSubview(imageView)
        itemView.alphaValue = 0
        return imageView
    }

    private func animateWorkspaceDeletionSnapshot(_ snapshot: NSImageView?) {
        guard let snapshot else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.deletionAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            let finalOrigin = NSPoint(x: snapshot.frame.origin.x, y: snapshot.frame.origin.y - Self.deletionAnimationOffset)
            snapshot.animator().setFrameOrigin(finalOrigin)
            snapshot.animator().alphaValue = 0
        } completionHandler: {
            DispatchQueue.main.async {
                snapshot.removeFromSuperview()
            }
        }
    }

    private func handleWorkspaceRename(id: UUID, newName: String) {
        guard let appModel = appModel else { return }
        appModel.renameWorkspace(id: id, newName: newName)
        reloadWorkspaces()
    }

    @objc private func handleWorkspaceRightClick(_ sender: NSMenuItem) {
        guard let workspaceId = sender.representedObject as? UUID else { return }
        contextWorkspaceId = workspaceId
    }

    private func showWorkspaceContextMenu(for workspaceId: UUID, at event: NSEvent) {
        guard let appModel = appModel else { return }
        guard let workspace = appModel.workspaces.first(where: { $0.id == workspaceId }) else { return }

        contextWorkspaceId = workspaceId

        let menu = NSMenu()

        // Rename option
        let renameItem = NSMenuItem(title: "Rename Workspace...", action: #selector(beginInlineRenameForContextWorkspace), keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        // Change Color submenu
        let colorItem = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
        colorItem.submenu = ContextMenuBuilder.workspaceColorSubmenu(
            currentColorId: workspace.colorId,
            target: self,
            colorAction: #selector(changeWorkspaceColor(_:)),
            customColorAction: #selector(chooseCustomWorkspaceColor)
        )
        menu.addItem(colorItem)

        // Browser Profile submenu
        if let bundleId = BrowserManager.resolveDefaultBrowserBundleId(),
           BrowserManager.supportsProfiles(bundleId) {
            let profiles = BrowserManager.profiles(for: bundleId)
            if !profiles.isEmpty {
                let profileSubmenu = NSMenu()
                let currentProfile = workspace.browserProfiles[bundleId]

                // "None" option to clear profile
                let noneItem = NSMenuItem(title: "None (default)", action: #selector(clearWorkspaceBrowserProfile), keyEquivalent: "")
                noneItem.target = self
                if currentProfile == nil {
                    noneItem.state = .on
                }
                profileSubmenu.addItem(noneItem)
                profileSubmenu.addItem(.separator())

                for profile in profiles {
                    let item = NSMenuItem(title: profile.displayName, action: #selector(setWorkspaceBrowserProfile(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = profile.directoryName
                    if currentProfile == profile.directoryName {
                        item.state = .on
                    }
                    profileSubmenu.addItem(item)
                }

                let profileItem = NSMenuItem(title: "Browser profile", action: nil, keyEquivalent: "")
                profileItem.submenu = profileSubmenu
                menu.addItem(profileItem)
            }
        }

        // Delete option
        menu.addItem(.separator())
        let deleteItem = NSMenuItem(title: "Delete Workspace...", action: #selector(deleteContextWorkspace), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.isEnabled = appModel.workspaces.count > 1
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: workspaceCollectionView)
    }

    @objc private func beginInlineRenameForContextWorkspace() {
        guard let workspaceId = contextWorkspaceId else { return }
        guard let appModel = appModel else { return }
        guard let index = appModel.workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }

        inlineRenameWorkspaceId = workspaceId

        DispatchQueue.main.async {
            let indexPath = IndexPath(item: index, section: 0)
            if let item = self.workspaceCollectionView.item(at: indexPath) as? WorkspaceCollectionViewItem {
                item.beginInlineRename()
            }
        }
    }

    @objc private func changeWorkspaceColor(_ sender: NSMenuItem) {
        guard let workspaceId = contextWorkspaceId else { return }
        guard let colorId = sender.representedObject as? WorkspaceColorId else { return }
        guard let appModel = appModel else { return }

        appModel.updateWorkspaceColor(id: workspaceId, colorId: colorId)
        reloadWorkspaces()
    }

    @objc private func chooseCustomWorkspaceColor() {
        guard let workspaceId = contextWorkspaceId else { return }
        guard let appModel = appModel else { return }
        guard let workspace = appModel.workspaces.first(where: { $0.id == workspaceId }) else { return }

        customColorTargetWorkspaceId = workspaceId
        let colorPanel = NSColorPanel.shared
        colorPanel.color = workspace.colorId.color
        colorPanel.setTarget(self)
        colorPanel.setAction(#selector(settingsCustomColorChanged(_:)))
        colorPanel.isContinuous = true
        colorPanel.makeKeyAndOrderFront(nil)
    }

    @objc private func settingsCustomColorChanged(_ sender: Any?) {
        guard let workspaceId = customColorTargetWorkspaceId else { return }
        guard let appModel = appModel else { return }
        let hex = NSColorPanel.shared.color.hexString
        appModel.updateWorkspaceColor(id: workspaceId, colorId: .custom(hex))
        reloadWorkspaces()
    }

    @objc private func setWorkspaceBrowserProfile(_ sender: NSMenuItem) {
        guard let workspaceId = contextWorkspaceId else { return }
        guard let profileDir = sender.representedObject as? String else { return }
        guard let bundleId = BrowserManager.resolveDefaultBrowserBundleId() else { return }
        appModel?.updateWorkspaceBrowserProfile(id: workspaceId, bundleId: bundleId, profile: profileDir)
        reloadWorkspaces()
    }

    @objc private func clearWorkspaceBrowserProfile() {
        guard let workspaceId = contextWorkspaceId else { return }
        guard let bundleId = BrowserManager.resolveDefaultBrowserBundleId() else { return }
        appModel?.updateWorkspaceBrowserProfile(id: workspaceId, bundleId: bundleId, profile: nil)
        reloadWorkspaces()
    }

    @objc private func deleteContextWorkspace() {
        guard let workspaceId = contextWorkspaceId else { return }
        handleWorkspaceDelete(id: workspaceId)
    }

    @objc private func handleWorkspaceScrollBoundsChanged() {
        for item in workspaceCollectionView.visibleItems() {
            (item as? WorkspaceCollectionViewItem)?.refreshHoverState()
        }
    }
}

// MARK: - NSCollectionViewDataSource

extension SettingsContentViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return appModel?.workspaces.count ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let appModel = appModel else {
            return NSCollectionViewItem()
        }

        let item = collectionView.makeItem(
            withIdentifier: NSUserInterfaceItemIdentifier("WorkspaceItem"),
            for: indexPath
        ) as! WorkspaceCollectionViewItem

        let workspace = appModel.workspaces[indexPath.item]
        let canDelete = appModel.workspaces.count > 1

        // Resolve profile display name
        var profileName: String?
        if let bundleId = BrowserManager.resolveDefaultBrowserBundleId(),
           let profileDir = workspace.browserProfiles[bundleId] {
            let profiles = BrowserManager.profiles(for: bundleId)
            profileName = profiles.first(where: { $0.directoryName == profileDir })?.displayName ?? profileDir
        }

        item.configure(
            workspace: workspace,
            canDelete: canDelete,
            profileName: profileName,
            onDelete: { [weak self] id in
                self?.handleWorkspaceDelete(id: id)
            },
            onRenameCommit: { [weak self] id, newName in
                self?.handleWorkspaceRename(id: id, newName: newName)
            }
        )

        return item
    }
}


// MARK: - NSCollectionViewDelegate

extension SettingsContentViewController: NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        return true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let appModel = appModel else {
            return nil
        }
        let workspace = appModel.workspaces[indexPath.item]

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(workspace.id.uuidString, forType: workspacePasteboardType)
        return pasteboardItem
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        // Only allow drop before items (for reordering)
        proposedDropOperation.pointee = .before

        // Show drop indicator
        let indexPath = proposedDropIndexPath.pointee as IndexPath
        let metrics = ListMetrics()

        if indexPath.item == 0 {
            // Drop at the beginning
            let indicatorFrame = CGRect(
                x: 0,
                y: 0,
                width: collectionView.bounds.width,
                height: 2
            )
            workspaceDropIndicator.showLine(in: indicatorFrame)
        } else if indexPath.item < (appModel?.workspaces.count ?? 0) {
            // Drop between items
            let y = CGFloat(indexPath.item) * (metrics.rowHeight + metrics.verticalGap) - metrics.verticalGap / 2
            let indicatorFrame = CGRect(
                x: 0,
                y: y,
                width: collectionView.bounds.width,
                height: 2
            )
            workspaceDropIndicator.showLine(in: indicatorFrame)
        } else {
            // Drop at the end
            let count = appModel?.workspaces.count ?? 0
            let y = CGFloat(count) * (metrics.rowHeight + metrics.verticalGap) - metrics.verticalGap / 2
            let indicatorFrame = CGRect(
                x: 0,
                y: y,
                width: collectionView.bounds.width,
                height: 2
            )
            workspaceDropIndicator.showLine(in: indicatorFrame)
        }

        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        // Hide drop indicator
        workspaceDropIndicator.hide()

        guard let appModel = appModel else {
            return false
        }
        guard let pasteboardItem = draggingInfo.draggingPasteboard.pasteboardItems?.first else {
            return false
        }
        guard let uuidString = pasteboardItem.string(forType: workspacePasteboardType) else {
            return false
        }
        guard let workspaceId = UUID(uuidString: uuidString) else {
            return false
        }
        guard let currentIndex = appModel.workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            return false
        }

        var targetIndex = indexPath.item

        // Adjust target index if dragging within the same list
        if currentIndex < targetIndex {
            targetIndex -= 1
        }

        // Perform the reorder
        appModel.reorderWorkspace(id: workspaceId, toIndex: targetIndex)
        reloadWorkspaces()

        return true
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        // Hide drop indicator when drag ends
        workspaceDropIndicator.hide()
    }
}

// MARK: - Workspace Context Menu Collection View

private final class WorkspaceContextMenuCollectionView: NSCollectionView {
    var onRightClick: ((UUID, NSEvent) -> Void)?

    weak var settingsController: SettingsContentViewController?

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point),
           let appModel = settingsController?.appModel {
            let workspace = appModel.workspaces[indexPath.item]
            onRightClick?(workspace.id, event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Call super to allow drag operations
        super.mouseDown(with: event)
    }
}

// MARK: - Flipped Content View

/// A custom NSView that uses flipped coordinates so content is anchored to the top
private final class FlippedContentView: NSView {
    override var isFlipped: Bool {
        return true
    }
}

// MARK: - Settings Button

/// A custom button with background and hover effect, styled like the dropdown container
private final class SettingsButton: NSButton {
    // Style constants
    private struct Style {
        static var baseBackgroundColor: NSColor { SettingsColors.fill }
        static var hoverBackgroundColor: NSColor { SettingsColors.fillStrong }
        static var textColor: NSColor { SettingsColors.ink }
        static var disabledBackgroundColor: NSColor { SettingsColors.fill }
        static var disabledTextColor: NSColor { SettingsColors.inkSecondary }

        static let cornerRadius: CGFloat = 8
        static let fontSize: CGFloat = 13
    }

    private var trackingArea: NSTrackingArea?
    private var spinner: NSProgressIndicator?
    private let originalTitle: String
    private var isLoading: Bool = false

    init(title: String) {
        self.originalTitle = title
        super.init(frame: .zero)
        self.title = title
        setupButton()
    }

    required init?(coder: NSCoder) {
        self.originalTitle = ""
        super.init(coder: coder)
        setupButton()
    }

    private func setupButton() {
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        font = NSFont.systemFont(ofSize: Style.fontSize)

        // Setup layer
        layer?.backgroundColor = resolvedCGColor(Style.baseBackgroundColor)
        layer?.cornerRadius = Style.cornerRadius

        // Set text color
        updateTextColor(Style.textColor)
    }

    private func updateTextColor(_ color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: Style.fontSize)
        ]
        attributedTitle = NSAttributedString(string: originalTitle, attributes: attributes)
    }

    func setLoading(_ loading: Bool) {
        self.isLoading = loading

        if loading {
            // Create and add spinner if it doesn't exist
            if spinner == nil {
                let progressIndicator = NSProgressIndicator()
                progressIndicator.style = .spinning
                progressIndicator.controlSize = .small
                progressIndicator.translatesAutoresizingMaskIntoConstraints = false

                // Force aqua appearance so the spinner renders as dark/black instead of white
                // This is necessary because NSProgressIndicator doesn't have a direct color API
                progressIndicator.appearance = NSAppearance(named: .aqua)

                addSubview(progressIndicator)

                // Position spinner to the right of the text
                NSLayoutConstraint.activate([
                    progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
                    progressIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                    progressIndicator.widthAnchor.constraint(equalToConstant: 16),
                    progressIndicator.heightAnchor.constraint(equalToConstant: 16)
                ])

                spinner = progressIndicator
            }

            // Apply disabled background styling (without actually disabling the button)
            layer?.backgroundColor = resolvedCGColor(Style.disabledBackgroundColor)

            // Update text color to #141414 with full opacity
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: Style.disabledTextColor,
                .font: NSFont.systemFont(ofSize: Style.fontSize)
            ]
            attributedTitle = NSAttributedString(string: originalTitle, attributes: attributes)

            // Show and start spinner
            spinner?.startAnimation(nil)
            spinner?.isHidden = false
        } else {
            // Hide and stop spinner
            spinner?.stopAnimation(nil)
            spinner?.isHidden = true

            // Restore enabled background styling
            layer?.backgroundColor = resolvedCGColor(Style.baseBackgroundColor)

            // Restore text color
            updateTextColor(Style.textColor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Prevent action if loading
        if isLoading {
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existingArea = trackingArea {
            removeTrackingArea(existingArea)
        }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        // Only show hover effect if not loading
        if !isLoading {
            layer?.backgroundColor = resolvedCGColor(Style.hoverBackgroundColor)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Restore appropriate background based on loading state
        if isLoading {
            layer?.backgroundColor = resolvedCGColor(Style.disabledBackgroundColor)
        } else {
            layer?.backgroundColor = resolvedCGColor(Style.baseBackgroundColor)
        }
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }
}

// MARK: - Workspace Drop Indicator View

private final class WorkspaceDropIndicatorView: NSView {
    private let lineThickness: CGFloat = 2
    private var accentColor: NSColor { SettingsColors.accent }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
    }

    func showLine(in frame: NSRect) {
        isHidden = false
        self.frame = frame
        layer?.cornerRadius = lineThickness / 2
        layer?.backgroundColor = resolvedCGColor(accentColor)
        layer?.borderWidth = 0
    }

    func hide() {
        isHidden = true
    }
}

extension Notification.Name {
    static let stowTintModeChanged = Notification.Name("StowTintModeChanged")
}
