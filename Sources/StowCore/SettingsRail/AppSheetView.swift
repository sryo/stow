import AppKit

/// The app sheet: Window, Keyboard and Appearance, plus a permissions line that shows
/// only when something is missing. It's the flyout behind the rail's sliders cell and,
/// in its `.page` style, the groups below Workspaces on the Settings page, so both
/// widths share one look. Every change goes through AppPreferences.
@MainActor
final class AppSheetView: RailFlippedView {
    enum Style { case flyout, page }

    static let width: CGFloat = 276

    let style: Style
    var onHeightChange: (() -> Void)?
    /// Import…, from the footer: the same source picker as File ▸ Import….
    var onImport: (() -> Void)?
    /// "All shortcuts…", from Keyboard: the owner pushes AllShortcutsView beside the sheet.
    var onShowAllShortcuts: ((NSView) -> Void)?

    private let preferences = AppPreferences.shared
    private let title = FlyoutLabel.text("App settings", size: 13, weight: .bold)
    private let version = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)
    private var sectionLabels: [AppSheetSection: NSTextField] = [:]
    private let syncsTag = SyncsTag()

    // Window
    private var windowControl: FlyoutSegmented!
    private var permissionRows: [PermissionRow] = []
    private let sideLabel = FlyoutLabel.text("Browser side", size: 11.5, color: FlyoutColors.inkSecondary)
    private var sideControl: FlyoutSegmented!
    private let windowHelp = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)
    private let tablineTitle = FlyoutLabel.text("Tabline", size: 13, weight: .medium)
    private let tablineDetail = FlyoutLabel.text("Tabs ride above your browser · ⌥⌘L", size: 11, color: FlyoutColors.inkSecondary)
    private let tablineSwitch = FlyoutSwitch(isOn: false, accessibilityLabel: "Tabline")
    private let loginTitle = FlyoutLabel.text("Open at login", size: 13, weight: .medium)
    private let loginDetail = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)
    private let loginSwitch = FlyoutSwitch(isOn: false, accessibilityLabel: "Open at login")
    private var loginError: String?

    // Keyboard
    private let toggleLabel = FlyoutLabel.text("Toggle Stow", size: 11.5, color: FlyoutColors.inkSecondary)
    private let frontTabLabel = FlyoutLabel.text("Stow front tab", size: 11.5, color: FlyoutColors.inkSecondary)
    let toggleRecorder = FlyoutShortcutRecorder(action: .toggleStow)
    let frontTabRecorder = FlyoutShortcutRecorder(action: .stowFrontTab)
    private let keyboardHelp = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)
    private let allShortcuts = FlyoutLink("All shortcuts…", fontSize: 11)
    private var keyboardStatus: (text: String, kind: FlyoutShortcutRecorder.StatusKind)?

    // Appearance
    private let tintLabel = FlyoutLabel.text("Page color", size: 11.5, color: FlyoutColors.inkSecondary)
    private var tintControl: FlyoutSegmented!
    private var tintSwatches: [TintSwatch] = []

    let footer = AppSheetFooterView(showsVersion: false)

    /// The workspace whose color the page-color previews use.
    var previewColor: WorkspaceColorId = .defaultColor() {
        didSet { tintSwatches.forEach { $0.colorId = previewColor } }
    }

    init(style: Style = .flyout) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 388))
        version.stringValue = "Stow " + AppSheetFooterView.versionString
        version.alignment = .right
        if style == .flyout {
            addSubview(title)
            addSubview(version)
            addSubview(footer)
            footer.onImport = { [weak self] in self?.onImport?() }
        }
        for section in AppSheet.sections {
            let label = FlyoutLabel.section(section.title)
            sectionLabels[section] = label
            addSubview(label)
        }
        syncsTag.text = style == .page ? "syncs with iPhone" : "syncs"
        addSubview(syncsTag)

        windowControl = FlyoutSegmented([
            .init(title: "Floating", leading: Self.glyph("macwindow")),
            .init(title: "On top", leading: Self.glyph("macwindow.on.rectangle")),
            .init(title: "Attached", leading: Self.glyph("sidebar.left")),
        ], selected: preferences.windowMode.rawValue, accessibilityLabel: "Window")
        windowControl.onChange = { [weak self] index in
            self?.preferences.setWindowMode(AppWindowMode(rawValue: index) ?? .floating)
        }
        sideControl = FlyoutSegmented([.init(title: "Left"), .init(title: "Right")],
                                      selected: preferences.browserSide, accessibilityLabel: "Browser side")
        sideControl.onChange = { [weak self] index in self?.preferences.setBrowserSide(index) }
        tablineDetail.toolTip = "The Tabline shows this workspace's links as tabs riding above your browser window."
        tablineSwitch.onChange = { [weak self] on in self?.preferences.setTabline(on) }
        loginSwitch.onChange = { [weak self] on in
            guard let self else { return }
            self.loginError = self.preferences.setOpenAtLogin(on)
            self.refresh()
        }

        for recorder in [toggleRecorder, frontTabRecorder] {
            recorder.onStatusChanged = { [weak self] text, kind in
                guard let self else { return }
                self.keyboardStatus = text.map { ($0, kind) }
                self.refreshKeyboardHelp()
            }
        }
        allShortcuts.target = self
        allShortcuts.action = #selector(showAllShortcuts(_:))

        let tints = StowTheme.TintMode.allCases
        tintSwatches = tints.map { TintSwatch(tint: $0) }
        tintControl = FlyoutSegmented(zip(tints.map(AppPreferences.tintTitle), tintSwatches).map { .init(title: $0, leading: $1) },
                                      selected: tints.firstIndex(of: preferences.tint) ?? 0, accessibilityLabel: "Page color")
        tintControl.onChange = { [weak self] index in self?.preferences.setTint(tints[index]) }

        for view in [windowControl!, sideLabel, sideControl!, windowHelp, tablineTitle, tablineDetail, tablineSwitch,
                     loginTitle, loginDetail, loginSwitch, toggleLabel, toggleRecorder, frontTabLabel, frontTabRecorder,
                     keyboardHelp, allShortcuts, tintLabel, tintControl!] as [NSView] {
            addSubview(view)
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.stowAppPreferencesChanged, .alwaysOnTopSettingChanged, .attachmentSettingChanged,
                     .tablineSettingChanged, .stowTintModeChanged, NSApplication.didBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(shortcutsChanged), name: .toggleSidebarShortcutChanged, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func glyph(_ name: String) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        view.imageScaling = .scaleNone
        view.frame = NSRect(x: 0, y: 0, width: 14, height: 12)
        view.setAccessibilityElement(false)
        return view
    }

    // MARK: State

    @objc func refresh() {
        let mode = preferences.windowMode
        windowControl.selectedIndex = mode.rawValue
        sideControl.selectedIndex = preferences.browserSide
        windowHelp.stringValue = AppSheet.windowHelp(mode)
        let needs = preferences.permissionNeeds
        if needs.map(\.reason) != permissionRows.map(\.need.reason) {
            permissionRows.forEach { $0.removeFromSuperview() }
            permissionRows = needs.map { need in
                let row = PermissionRow(need: need)
                row.onFix = { [weak self] in self?.preferences.fix(need) }
                addSubview(row)
                return row
            }
        }
        tablineSwitch.isOn = preferences.tablineEnabled
        loginSwitch.isOn = preferences.openAtLogin
        if let loginError {
            loginDetail.stringValue = loginError
            loginDetail.textColor = FlyoutColors.danger
        } else if preferences.openAtLoginNeedsApproval {
            loginDetail.stringValue = "Allow Stow in System Settings › Login Items"
            loginDetail.textColor = FlyoutColors.warning
        } else {
            loginDetail.stringValue = ""
        }
        tintControl.selectedIndex = StowTheme.TintMode.allCases.firstIndex(of: preferences.tint) ?? 0
        footer.refresh()
        refreshKeyboardHelp()
    }

    @objc private func shortcutsChanged() {
        toggleRecorder.reload()
        frontTabRecorder.reload()
    }

    private func refreshKeyboardHelp() {
        if let status = keyboardStatus {
            keyboardHelp.stringValue = status.text
            switch status.kind {
            case .help: keyboardHelp.textColor = FlyoutColors.inkSecondary
            case .success: keyboardHelp.textColor = FlyoutColors.inkSecondary
            case .warning: keyboardHelp.textColor = FlyoutColors.warning
            case .danger: keyboardHelp.textColor = FlyoutColors.danger
            }
            keyboardHelp.toolTip = status.text
        } else {
            keyboardHelp.stringValue = style == .page ? "Both work from any app" : "Works from any app."
            keyboardHelp.textColor = FlyoutColors.inkSecondary
            keyboardHelp.toolTip = nil
        }
        needsLayout = true
        onHeightChange?()
    }

    @objc private func showAllShortcuts(_ sender: NSView) {
        onShowAllShortcuts?(sender)
    }

    // MARK: Layout

    var preferredHeight: CGFloat { layoutPieces(apply: false, width: bounds.width) }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat { layoutPieces(apply: false, width: width) }

    override func layout() {
        super.layout()
        layoutPieces(apply: true, width: bounds.width)
    }

    /// Lays everything out top to bottom and returns the height it needs. Below 236pt
    /// of content, labels stack above their controls.
    @discardableResult
    private func layoutPieces(apply: Bool, width: CGFloat) -> CGFloat {
        let pad: CGFloat = style == .flyout ? 12 : SettingsMetrics.rowPadding
        let w = max(60, width - pad * 2)
        let stacked = w < 236
        func place(_ view: NSView, _ rect: NSRect) { if apply { view.frame = rect } }
        var y: CGFloat = style == .flyout ? 12 : 0
        if style == .flyout {
            place(title, NSRect(x: pad + 2, y: y, width: 160, height: 16))
            place(version, NSRect(x: width - pad - 100, y: y + 2, width: 98, height: 14))
            y += 16 + 2
        }

        func header(_ section: AppSheetSection, first: Bool = false) {
            y += first && style == .page ? 4 : 11
            if let label = sectionLabels[section] { place(label, NSRect(x: pad + 2, y: y, width: w - 2, height: 12)) }
            y += 12 + 5
        }
        func line(_ label: NSTextField, _ control: NSView, height: CGFloat) {
            y += 6
            if stacked {
                place(label, NSRect(x: pad, y: y, width: w, height: 14))
                y += 14 + 3
                place(control, NSRect(x: pad, y: y, width: w, height: height))
            } else {
                place(label, NSRect(x: pad, y: y + (height - 14) / 2, width: 84, height: 14))
                place(control, NSRect(x: pad + 84 + 4, y: y, width: w - 88, height: height))
            }
            y += height
        }
        func helpLine(_ label: NSTextField) {
            y += 5
            place(label, NSRect(x: pad + 2, y: y, width: w - 2, height: 14))
            y += 14
        }
        func switchRow(_ titleLabel: NSTextField, _ detail: NSTextField, _ toggle: FlyoutSwitch) {
            y += 8
            let hasDetail = !detail.stringValue.isEmpty
            let h: CGFloat = hasDetail ? 32 : 18
            place(titleLabel, NSRect(x: pad, y: y, width: w - 40, height: 17))
            detail.isHidden = !hasDetail
            if hasDetail { place(detail, NSRect(x: pad, y: y + 17, width: w - 40, height: 14)) }
            place(toggle, NSRect(x: pad + w - 30, y: y + (h - 18) / 2, width: 30, height: 18))
            y += h
        }

        for (index, section) in AppSheet.sections.enumerated() {
            header(section, first: index == 0)
            switch section {
            case .window:
                place(windowControl, NSRect(x: pad, y: y, width: w, height: 28))
                y += 28
                for row in permissionRows {
                    y += 6
                    let h = row.height(forWidth: w)
                    place(row, NSRect(x: pad, y: y, width: w, height: h))
                    y += h
                }
                let attached = AppSheet.showsBrowserSide(preferences.windowMode)
                sideLabel.isHidden = !attached
                sideControl.isHidden = !attached
                if attached { line(sideLabel, sideControl, height: 28) }
                helpLine(windowHelp)
                switchRow(tablineTitle, tablineDetail, tablineSwitch)
                switchRow(loginTitle, loginDetail, loginSwitch)
            case .keyboard:
                line(toggleLabel, toggleRecorder, height: 26)
                line(frontTabLabel, frontTabRecorder, height: 26)
                y += 6
                let link = allShortcuts.fittingWidth
                // Narrow: the help gets the whole line and the link drops below it.
                let helpWidth = stacked ? w - 2 : w - link - 10
                let needed = (keyboardHelp.stringValue as NSString).size(withAttributes: [.font: keyboardHelp.font as Any]).width + 4
                let lines: CGFloat = needed > helpWidth ? 2 : 1
                keyboardHelp.maximumNumberOfLines = Int(lines)
                keyboardHelp.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
                place(keyboardHelp, NSRect(x: pad + 2, y: y, width: helpWidth, height: 14 * lines))
                if stacked {
                    y += 14 * lines + 3
                    place(allShortcuts, NSRect(x: pad + 2, y: y, width: link, height: 14))
                    y += 14
                } else {
                    place(allShortcuts, NSRect(x: pad + w - link, y: y, width: link, height: 14))
                    y += 14 * lines
                }
            case .appearance:
                // The "syncs" note sits at the header's end when there's room for both.
                let tag = syncsTag.fittingWidth
                let headerWidth = (sectionLabels[.appearance]?.attributedStringValue.size().width ?? 0) + 12
                syncsTag.isHidden = headerWidth + tag > w
                place(syncsTag, NSRect(x: pad + w - tag, y: y - 17, width: tag, height: 12))
                line(tintLabel, tintControl, height: 28)
            }
        }
        if style == .flyout {
            y += 12
            place(footer, NSRect(x: pad, y: y, width: w, height: AppSheetFooterView.height))
            y += AppSheetFooterView.height
            return y + 10
        }
        return y + 4
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tintSwatches.forEach { $0.needsDisplay = true }
    }
}

// MARK: - Permission row

/// "! Tabline and Attached need Accessibility   [Fix…]"
private final class PermissionRow: RailFlippedView {
    let need: PermissionNeed
    var onFix: (() -> Void)?
    private let mark = FlyoutLabel.text("!", size: 11, weight: .heavy, color: FlyoutColors.warning)
    private let text = FlyoutLabel.wrapping("", size: 11.5, color: FlyoutColors.ink)
    private let fix = FlyoutButton("Fix…", height: 22, fontSize: 11.5)

    init(need: PermissionNeed) {
        self.need = need
        super.init(frame: .zero)
        text.stringValue = need.reason
        text.maximumNumberOfLines = 2
        fix.target = self
        fix.action = #selector(fixTapped)
        fix.setAccessibilityLabel("Fix: \(need.reason)")
        addSubview(mark)
        addSubview(text)
        addSubview(fix)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fixTapped() { onFix?() }

    private func textWidth(_ width: CGFloat) -> CGFloat { width - 12 - fix.fittingWidth - 10 }

    func height(forWidth width: CGFloat) -> CGFloat {
        let h = text.attributedStringValue.boundingRect(with: NSSize(width: textWidth(width) - 4, height: 60),
                                                        options: [.usesLineFragmentOrigin]).height
        return max(22, ceil(h) + 2)
    }

    override func layout() {
        super.layout()
        let f = fix.fittingWidth
        mark.frame = NSRect(x: 2, y: (bounds.height - 14) / 2, width: 8, height: 14)
        text.frame = NSRect(x: 12, y: 0, width: textWidth(bounds.width), height: bounds.height)
        fix.frame = NSRect(x: bounds.width - f, y: (bounds.height - 22) / 2, width: f, height: 22)
    }
}

// MARK: - Syncs tag

/// "☁ syncs": Appearance's note that page color follows you to the iPhone.
private final class SyncsTag: NSView {
    private let icon = NSImageView()
    private let label = FlyoutLabel.text("", size: 10.5, color: FlyoutColors.inkSecondary)
    var text: String = "" { didSet { label.stringValue = text; needsLayout = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = NSImage(systemSymbolName: "icloud.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8.5, weight: .medium))
        icon.contentTintColor = FlyoutColors.inkSecondary
        addSubview(icon)
        addSubview(label)
        toolTip = "Page color is the same on your Mac and iPhone."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var fittingWidth: CGFloat { 13 + ceil(label.intrinsicContentSize.width) + 5 }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: 1, width: 12, height: 10)
        label.frame = NSRect(x: 13, y: -1, width: bounds.width - 13, height: 13)
    }
}

// MARK: - Footer

/// "☁ Synced · 2 min ago            Import…": the iCloud line (red with a fix when sync
/// is off) and the Import… link. On the Settings page it adds "· Stow 0.4".
@MainActor
final class AppSheetFooterView: RailFlippedView {
    static let height: CGFloat = 26
    static var versionString: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    var onImport: (() -> Void)?
    private let line = NSView()
    private let cloud = NSImageView()
    private let status = FlyoutLabel.text("", size: 11.5, color: FlyoutColors.inkSecondary)
    private let fixButton = FlyoutLink("Fix…", fontSize: 11.5)
    private let importLink = FlyoutLink("Import…")
    private let separator = FlyoutLabel.text("·", size: 11.5, color: FlyoutColors.inkSecondary)
    private let version = FlyoutLabel.text("", size: 11.5, color: FlyoutColors.inkSecondary)
    private let showsVersion: Bool
    private var timer: Timer?
    private var isError = false

    init(showsVersion: Bool) {
        self.showsVersion = showsVersion
        super.init(frame: .zero)
        line.wantsLayer = true
        addSubview(line)
        cloud.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        addSubview(cloud)
        addSubview(status)
        fixButton.target = self
        fixButton.action = #selector(openICloudSettings)
        fixButton.toolTip = "Open iCloud settings"
        addSubview(fixButton)
        importLink.target = self
        importLink.action = #selector(importTapped)
        importLink.toolTip = "Import from Arc, Chrome, Safari, an HTML bookmarks file or a Stow file"
        addSubview(importLink)
        version.stringValue = "Stow " + Self.versionString
        if showsVersion {
            addSubview(separator)
            addSubview(version)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .cloudSyncStatusChanged, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        // "2 min ago" keeps counting while the sheet is open.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    @objc func refresh() {
        let sync = CloudSyncManager.shared
        let line = AppSheet.syncLine(availability: sync.availability, lastSync: sync.lastSyncDate, signedOut: sync.isSignedOut)
        status.stringValue = line.text
        status.toolTip = line.isError && sync.availability == .disabledNoProvisioningProfile
            ? "\(line.text). Development builds aren't signed for iCloud." : line.text
        isError = line.isError
        // A signed-out account can be fixed in System Settings; an unsigned build can't.
        fixButton.isHidden = !(line.isError && sync.availability != .disabledNoProvisioningProfile)
        applyColors()
        needsLayout = true
    }

    private func applyColors() {
        let color = isError ? FlyoutColors.danger : FlyoutColors.inkSecondary
        status.textColor = color
        cloud.contentTintColor = color
        line.layer?.backgroundColor = flyoutCG(FlyoutColors.line)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let y: CGFloat = 10
        cloud.frame = NSRect(x: 0, y: y, width: 16, height: 13)
        var right = bounds.width
        if showsVersion {
            let v = ceil(version.intrinsicContentSize.width) + 6
            version.frame = NSRect(x: right - v, y: y - 1, width: v, height: 15)
            right -= v + 2
            separator.frame = NSRect(x: right - 8, y: y - 1, width: 8, height: 15)
            right -= 10
        }
        let i = importLink.fittingWidth
        importLink.frame = NSRect(x: right - i, y: y - 1, width: i, height: 15)
        right -= i + 8
        if !fixButton.isHidden {
            let f = fixButton.fittingWidth
            fixButton.frame = NSRect(x: right - f, y: y - 1, width: f, height: 15)
            right -= f + 6
        }
        status.frame = NSRect(x: 19, y: y - 1, width: max(0, right - 19), height: 15)
    }

    @objc private func importTapped() { onImport?() }

    @objc private func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings:icloud") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - All shortcuts

/// "All shortcuts…": every Stow shortcut, read from the main menu (AppMenus) and the
/// list's own keys, so the list can't go stale. Menu shortcuts can be changed in System
/// Settings › Keyboard › Keyboard Shortcuts › App Shortcuts.
@MainActor
enum AllShortcuts {
    struct Row: Equatable {
        var title: String
        var keys: String
    }

    struct Section {
        var title: String
        var rows: [Row]
    }

    /// Keys the list handles itself (NodeListViewController, MainViewController).
    static let listKeys: [Row] = [
        Row(title: "Search", keys: "/"),
        Row(title: "Rename", keys: "F2"),
        Row(title: "Row actions", keys: "⌥↩"),
        Row(title: "Archive", keys: "⌘⌫"),
        Row(title: "Add to selection", keys: "⌥Space"),
        Row(title: "Open by letter, after ⌘J", keys: "a–z"),
    ]

    /// Commands every Mac app has; listing them would bury Stow's own.
    private static let standardActions: Set<String> = ["undo:", "redo:", "cut:", "copy:", "selectAll:",
                                                       "performMiniaturize:", "terminate:"]

    static func isStandard(_ item: NSMenuItem) -> Bool {
        item.action.map { standardActions.contains(NSStringFromSelector($0)) } ?? false
    }

    private static let titleOverrides = ["Paste": "Paste a link"]

    static func sections() -> [Section] {
        let store = ShortcutStore()
        let anyApp = HotkeyAction.allCases.map { action in
            Row(title: action.title, keys: store.shortcut(for: action)?.displayString ?? "None")
        }
        var menus: [Row] = []
        var workspaceRowAdded = false
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu); continue }
                guard !item.isSeparatorItem, !item.keyEquivalent.isEmpty, !isStandard(item) else { continue }
                let keys = display(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
                if item.action == #selector(AppMenuActions.switchToWorkspaceByTag(_:)) {
                    // Workspace 1…9 read as one row.
                    guard !workspaceRowAdded else { continue }
                    workspaceRowAdded = true
                    menus.append(Row(title: "Workspace 1–9", keys: String(keys.dropLast()) + "1–9"))
                    continue
                }
                let title = item.title.replacingOccurrences(of: "…", with: "")
                menus.append(Row(title: titleOverrides[title] ?? title, keys: keys))
            }
        }
        walk(AppMenus.build(target: nil))
        return [Section(title: "Any app", rows: anyApp), Section(title: "Menus", rows: menus),
                Section(title: "In the list", rows: listKeys)]
    }

    static func rows() -> [Row] { sections().flatMap(\.rows) }

    /// A menu key equivalent as the menu bar draws it: "⇧⌘N", "⌃⇥".
    static func display(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var mods = modifiers
        // An uppercase key equivalent implies Shift.
        if key.count == 1, let c = key.first, c.isLetter, c.isUppercase { mods.insert(.shift) }
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        switch key {
        case "\t": text += "⇥"
        case "\r": text += "↩"
        case "\u{8}", "\u{7f}": text += "⌫"
        case " ": text += "Space"
        default: text += key.uppercased()
        }
        return text
    }
}

/// The All shortcuts flyout, pushed beside the app sheet.
@MainActor
final class AllShortcutsView: RailFlippedView {
    static let width: CGFloat = 264
    private static let rowHeight: CGFloat = 20
    private static let pad: CGFloat = 12

    let note = FlyoutLabel.wrapping("Change menu shortcuts in System Settings › Keyboard › Keyboard Shortcuts.", size: 10.5)
    private(set) var preferredSize = NSSize(width: AllShortcutsView.width, height: 0)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 0))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("All shortcuts")
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let pad = Self.pad, width = Self.width
        var y: CGFloat = 12
        let title = FlyoutLabel.text("All shortcuts", size: 13, weight: .bold)
        title.frame = NSRect(x: pad + 2, y: y, width: width - pad * 2, height: 16)
        addSubview(title)
        y += 16
        for section in AllShortcuts.sections() where !section.rows.isEmpty {
            y += 10
            let header = FlyoutLabel.section(section.title)
            header.frame = NSRect(x: pad + 2, y: y, width: width - pad * 2, height: 12)
            addSubview(header)
            y += 12 + 3
            for row in section.rows {
                let keys = FlyoutLabel.text(row.keys, size: 12, weight: .medium, color: FlyoutColors.inkSecondary)
                keys.alignment = .right
                let keyWidth = ceil(keys.intrinsicContentSize.width) + 2
                keys.frame = NSRect(x: width - pad - keyWidth, y: y + 2, width: keyWidth, height: 16)
                keys.setAccessibilityElement(false)
                let name = FlyoutLabel.text(row.title, size: 12)
                name.frame = NSRect(x: pad, y: y + 2, width: width - pad * 2 - keyWidth - 8, height: 16)
                name.setAccessibilityLabel("\(row.title), \(row.keys)")
                addSubview(name)
                addSubview(keys)
                y += Self.rowHeight
            }
        }
        y += 10
        let noteWidth = width - pad * 2
        let needed = note.attributedStringValue.boundingRect(with: NSSize(width: noteWidth - 4, height: 200),
                                                             options: [.usesLineFragmentOrigin]).height
        note.frame = NSRect(x: pad, y: y, width: noteWidth, height: ceil(needed) + 1)
        addSubview(note)
        y += note.frame.height + 12
        preferredSize = NSSize(width: width, height: y)
        frame.size = preferredSize
    }
}

// MARK: - Tint swatch

/// The 16×11 page preview leading each Page color segment.
private final class TintSwatch: NSView {
    let tint: StowTheme.TintMode
    var colorId: WorkspaceColorId = .defaultColor() { didSet { needsDisplay = true } }

    init(tint: StowTheme.TintMode) {
        self.tint = tint
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 11))
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        StowTheme.colors(for: colorId, tint: tint).surface.setFill()
        path.fill()
        NSColor(white: 0, alpha: 0.2).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        edge.lineWidth = 1
        edge.stroke()
    }
}

extension Notification.Name {
    /// Import… from a Settings footer: AppDelegate shows the File ▸ Import… source picker.
    static let stowShowImport = Notification.Name("StowShowImport")
}
