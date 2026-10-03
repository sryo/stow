import AppKit

/// The app sheet behind the rail's quiet cell: everything that isn't about one
/// workspace, in AppSheet.sections order. It changes settings through AppPreferences
/// (shared with the Settings page) and hands Import to the Settings page's importer.
@MainActor
final class AppSheetView: RailFlippedView {
    static let width: CGFloat = 276

    var onImportArc: (() -> Void)?
    var onImportFile: (() -> Void)?
    var onHeightChange: (() -> Void)?

    private let preferences = AppPreferences.shared
    private let title = FlyoutLabel.text("App settings", size: 13, weight: .bold)
    private let version = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)
    private var sectionLabels: [AppSheetSection: NSTextField] = [:]

    private var themeControl: FlyoutSegmented!
    private var tintControl: FlyoutSegmented!
    private var tintSwatches: [TintSwatch] = []
    private var windowControl: FlyoutSegmented!
    private let windowHelp = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)
    private let warningMark = FlyoutLabel.text("!", size: 11, weight: .heavy, color: FlyoutColors.warning)
    private let grantButton = FlyoutButton("Open Settings…", height: 20, fontSize: 11)
    private var sideControl: FlyoutSegmented!
    private let browserRow = FlyoutPopRow(symbol: nil, accessibilityLabel: "Open links in")
    private let shortcutRecorder = ShortcutRecorderView()
    private let shortcutStatus = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)
    private let footerLine = NSView()
    private let importLabel = FlyoutLabel.text("Import", size: 11.5, color: FlyoutColors.inkSecondary)
    private let arcButton = FlyoutButton("From Arc…", height: 22, fontSize: 11.5)
    private let fileButton = FlyoutButton("From file…", height: 22, fontSize: 11.5)
    private let importStatus = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)
    private var lineLabels: [NSTextField] = []
    private var browsers: [AppPreferences.BrowserChoice] = []

    /// The workspace whose color the page-color previews use.
    var previewColor: WorkspaceColorId = .defaultColor() {
        didSet { tintSwatches.forEach { $0.colorId = previewColor } }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 388))
        version.stringValue = "Stow " + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
        version.alignment = .right
        addSubview(title)
        addSubview(version)
        for section in AppSheet.sections where section != .importing {
            let label = FlyoutLabel.section(section.title)
            sectionLabels[section] = label
            addSubview(label)
        }

        themeControl = FlyoutSegmented([.init(title: "System"), .init(title: "Light"), .init(title: "Dark")],
                                       selected: preferences.theme.rawValue, accessibilityLabel: "Theme")
        themeControl.onChange = { [weak self] index in
            self?.preferences.setTheme(AppPreferences.Theme(rawValue: index) ?? .system)
        }
        let tints = StowTheme.TintMode.allCases
        tintSwatches = tints.map { TintSwatch(tint: $0) }
        tintControl = FlyoutSegmented(zip(["Full", "Soft", "None"], tintSwatches).map { .init(title: $0, leading: $1) },
                                      selected: tints.firstIndex(of: preferences.tint) ?? 0, accessibilityLabel: "Page color")
        tintControl.onChange = { [weak self] index in self?.preferences.setTint(tints[index]) }

        windowControl = FlyoutSegmented([
            .init(title: "Floating", leading: Self.glyph("macwindow")),
            .init(title: "On top", leading: Self.glyph("macwindow.on.rectangle")),
            .init(title: "Attached", leading: Self.glyph("sidebar.left")),
        ], selected: preferences.windowMode.rawValue, accessibilityLabel: "Window")
        windowControl.onChange = { [weak self] index in
            self?.preferences.setWindowMode(AppWindowMode(rawValue: index) ?? .floating)
        }
        grantButton.target = self
        grantButton.action = #selector(grantTapped)
        sideControl = FlyoutSegmented([.init(title: "Left"), .init(title: "Right")],
                                      selected: preferences.browserSide, accessibilityLabel: "Browser side")
        sideControl.onChange = { [weak self] index in self?.preferences.setBrowserSide(index) }

        browserRow.menuProvider = { [weak self] in self?.browserMenu() }
        shortcutRecorder.onShortcutChanged = { _ in
            NotificationCenter.default.post(name: .toggleSidebarShortcutChanged, object: nil)
        }
        shortcutRecorder.onStatusChanged = { [weak self] text, _ in
            guard let self else { return }
            self.shortcutStatus.stringValue = text ?? ""
            self.needsLayout = true
            self.onHeightChange?()
        }
        shortcutRecorder.translatesAutoresizingMaskIntoConstraints = true

        footerLine.wantsLayer = true
        arcButton.target = self
        arcButton.action = #selector(arcTapped)
        fileButton.target = self
        fileButton.action = #selector(fileTapped)

        for (text, _) in [("Theme", 0), ("Page color", 1), ("Browser side", 2), ("Open links in", 3), ("Toggle Stow", 4)] {
            let label = FlyoutLabel.text(text, size: 11.5, color: FlyoutColors.inkSecondary)
            lineLabels.append(label)
            addSubview(label)
        }
        for view in [themeControl!, tintControl!, windowControl!, windowHelp, warningMark, grantButton, sideControl!, browserRow,
                     shortcutRecorder, shortcutStatus, footerLine, importLabel, arcButton, fileButton, importStatus] as [NSView] {
            addSubview(view)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .stowAppPreferencesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .alwaysOnTopSettingChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .attachmentSettingChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSApplication.didBecomeActiveNotification, object: nil)
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
        browsers = preferences.browserChoices()
        themeControl.selectedIndex = preferences.theme.rawValue
        tintControl.selectedIndex = StowTheme.TintMode.allCases.firstIndex(of: preferences.tint) ?? 0
        let mode = preferences.windowMode
        windowControl.selectedIndex = mode.rawValue
        let missing = preferences.needsAccessibility
        warningMark.isHidden = !missing
        grantButton.isHidden = !missing
        if missing {
            windowHelp.stringValue = "Needs Accessibility access"
            windowHelp.textColor = FlyoutColors.ink
        } else if mode == .attached {
            windowHelp.stringValue = "Attached to the front browser window"
            windowHelp.textColor = FlyoutColors.inkSecondary
        } else {
            windowHelp.stringValue = ""
        }
        sideControl.selectedIndex = preferences.browserSide
        sideControl.isEnabled = mode == .attached && !missing
        let selected = preferences.selectedBrowserIndex(in: browsers)
        let name = browsers.indices.contains(selected) ? browsers[selected].name : "Browser I'm using"
        browserRow.set(title: name == "Browser I'm using" ? "The browser I’m using" : name, detail: nil)
        needsLayout = true
        onHeightChange?()
    }

    func showImportStatus(_ text: String, success: Bool) {
        importStatus.stringValue = text
        importStatus.textColor = success ? FlyoutColors.inkSecondary : FlyoutColors.danger
        arcButton.title = "From Arc…"
        needsLayout = true
        onHeightChange?()
    }

    private func browserMenu() -> NSMenu {
        let menu = NSMenu()
        let selected = preferences.selectedBrowserIndex(in: browsers)
        for (index, choice) in browsers.enumerated() {
            let item = NSMenuItem(title: choice.bundleId == nil ? "The browser I’m using" : choice.name, action: #selector(browserPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selected ? .on : .off
            if let icon = choice.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
            if index == 0 && browsers.count > 1 { menu.addItem(.separator()) }
        }
        return menu
    }

    @objc private func browserPicked(_ sender: NSMenuItem) {
        guard browsers.indices.contains(sender.tag) else { return }
        preferences.setBrowser(browsers[sender.tag].bundleId)
    }

    @objc private func grantTapped() { preferences.openAccessibilitySettings() }

    @objc private func arcTapped() {
        arcButton.title = "Importing…"
        needsLayout = true
        onImportArc?()
    }

    @objc private func fileTapped() { onImportFile?() }

    // MARK: Layout

    var preferredHeight: CGFloat {
        layoutPieces(apply: false)
    }

    override func layout() {
        super.layout()
        _ = layoutPieces(apply: true)
    }

    /// Lays everything out top to bottom and returns the height it needs.
    @discardableResult
    private func layoutPieces(apply: Bool) -> CGFloat {
        let pad: CGFloat = 12, w = Self.width - pad * 2
        func place(_ view: NSView, _ rect: NSRect) { if apply { view.frame = rect } }
        var y: CGFloat = 12
        place(title, NSRect(x: pad + 2, y: y, width: 160, height: 16))
        place(version, NSRect(x: Self.width - pad - 100, y: y + 2, width: 98, height: 14))
        y += 16 + 2

        func header(_ section: AppSheetSection) {
            y += 11
            if let label = sectionLabels[section] { place(label, NSRect(x: pad + 2, y: y, width: w, height: 12)) }
            y += 12 + 5
        }
        func line(_ labelIndex: Int, _ control: NSView, height: CGFloat) {
            y += 6
            place(lineLabels[labelIndex], NSRect(x: pad, y: y + (height - 14) / 2, width: 76, height: 14))
            place(control, NSRect(x: pad + 76 + 8, y: y, width: w - 84, height: height))
            y += height
        }

        for section in AppSheet.sections {
            switch section {
            case .appearance:
                header(section)
                line(0, themeControl, height: 28)
                line(1, tintControl, height: 28)
            case .window:
                header(section)
                place(windowControl, NSRect(x: pad, y: y, width: w, height: 28))
                y += 28
                if !windowHelp.stringValue.isEmpty {
                    y += 5
                    if preferences.needsAccessibility {
                        // The warning wraps beside its button, as in the concept.
                        let g = grantButton.fittingWidth
                        windowHelp.maximumNumberOfLines = 2
                        windowHelp.lineBreakMode = .byWordWrapping
                        place(warningMark, NSRect(x: pad + 2, y: y + 7, width: 8, height: 14))
                        place(windowHelp, NSRect(x: pad + 12, y: y, width: w - 12 - g - 10, height: 30))
                        place(grantButton, NSRect(x: Self.width - pad - g, y: y + 5, width: g, height: 20))
                        y += 30
                    } else {
                        windowHelp.maximumNumberOfLines = 1
                        place(windowHelp, NSRect(x: pad + 2, y: y, width: w, height: 14))
                        y += 14
                    }
                }
                windowHelp.isHidden = windowHelp.stringValue.isEmpty
                line(2, sideControl, height: 28)
            case .browser:
                header(section)
                line(3, browserRow, height: 26)
            case .shortcut:
                header(section)
                line(4, shortcutRecorder, height: 26)
                shortcutStatus.isHidden = shortcutStatus.stringValue.isEmpty
                if !shortcutStatus.isHidden {
                    y += 4
                    place(shortcutStatus, NSRect(x: pad + 2, y: y, width: w - 2, height: 14))
                    y += 14
                }
            case .importing:
                y += 12
                place(footerLine, NSRect(x: pad, y: y, width: w, height: 1))
                y += 1 + 9
                let f = fileButton.fittingWidth, a = arcButton.fittingWidth
                place(fileButton, NSRect(x: Self.width - pad - f, y: y, width: f, height: 22))
                place(arcButton, NSRect(x: Self.width - pad - f - 6 - a, y: y, width: a, height: 22))
                place(importLabel, NSRect(x: pad, y: y + 4, width: 60, height: 14))
                y += 22
                importStatus.isHidden = importStatus.stringValue.isEmpty
                if !importStatus.isHidden {
                    y += 5
                    place(importStatus, NSRect(x: pad, y: y, width: w, height: 14))
                    y += 14
                }
            }
        }
        if apply { footerLine.layer?.backgroundColor = flyoutCG(FlyoutColors.line) }
        return y + 10
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        footerLine.layer?.backgroundColor = flyoutCG(FlyoutColors.line)
        tintSwatches.forEach { $0.needsDisplay = true }
    }
}

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
