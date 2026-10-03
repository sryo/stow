import AppKit

/// Tabline: the current workspace as a row of tabs riding the top edge of whichever
/// browser window is in front (below it when there's no room above). It never takes
/// focus, so clicking a tab opens the site in the browser you're using.
@MainActor
final class TablineController {
    static let shared = TablineController()

    static let defaultsKey = "tablineEnabled"
    private static let height: CGFloat = 30

    /// Supplies the current workspace's name, color and links.
    var contentProvider: (() -> (name: String, colorId: WorkspaceColorId, links: [Link]))?
    var onOpenLink: ((Link) -> Void)?

    private var panel: NSPanel?
    private let strip = TablineStripView()
    private var timer: Timer?
    private var lastFrame: NSRect = .zero

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            newValue ? start() : stop()
        }
    }

    private init() {}

    func startIfEnabled() {
        if isEnabled { start() }
    }

    private func start() {
        if !AXIsProcessTrusted() {
            // Reading the browser window's frame needs Accessibility; prompt the same way attach mode does.
            WindowAttachmentService.shared.requestAccessibilityPermissions()
        }
        if panel == nil { makePanel() }
        reload()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        track()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    private func makePanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: Self.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        strip.onOpen = { [weak self] link in self?.onOpenLink?(link) }
        panel.contentView = strip
        self.panel = panel
    }

    /// Refreshes the tabs from the current workspace.
    func reload() {
        guard let content = contentProvider?() else { return }
        strip.configure(name: content.name, colors: StowTheme.colors(for: content.colorId), links: content.links)
    }

    // MARK: - Tracking the front browser window

    private func track() {
        guard let panel else { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleId = front.bundleIdentifier,
              bundleId == ActiveBrowserTracker.shared.lastActiveBundleId,
              let frame = frontWindowFrame(of: front) else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let target = placement(for: frame)
        if target != lastFrame || !panel.isVisible {
            lastFrame = target
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
        }
    }

    /// Above the window when there's room, otherwise below it, otherwise just inside its bottom edge.
    private func placement(for window: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(window) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? window
        let width = max(200, window.width - 16)
        let x = window.minX + 8
        let h = Self.height
        if window.maxY + h + 2 <= visible.maxY { return NSRect(x: x, y: window.maxY + 2, width: width, height: h) }
        if window.minY - h - 2 >= visible.minY { return NSRect(x: x, y: window.minY - h - 2, width: width, height: h) }
        return NSRect(x: x, y: window.minY + 6, width: width, height: h)
    }

    private func frontWindowFrame(of app: NSRunningApplication) -> NSRect? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        let element = window as! AXUIElement
        var positionRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let position = positionRef, let size = sizeRef else { return nil }
        var point = CGPoint.zero, cgSize = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &point)
        AXValueGetValue(size as! AXValue, .cgSize, &cgSize)
        // Accessibility uses a top-left origin on the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: point.x, y: primaryHeight - point.y - cgSize.height, width: cgSize.width, height: cgSize.height)
    }
}

/// The tab row: a workspace chip, then one tab per link (favicon and title), with the
/// rest in a "…" menu.
private final class TablineStripView: NSView {
    var onOpen: ((Link) -> Void)?
    private var links: [Link] = []
    private var colors = StowTheme.colors(for: .defaultColor())
    private var name = ""
    private var tabButtons: [NSButton] = []
    private let chip = NSButton()
    private let moreButton = NSButton()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        chip.isBordered = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 6
        addSubview(chip)
        moreButton.isBordered = false
        moreButton.title = "…"
        moreButton.target = self
        moreButton.action = #selector(showMore)
        addSubview(moreButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, colors: StowTheme.Colors, links: [Link]) {
        self.name = name
        self.colors = colors
        self.links = links
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons = links.enumerated().map { i, link in
            let b = NSButton(title: link.title, target: self, action: #selector(tabTapped(_:)))
            b.tag = i
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.lineBreakMode = .byTruncatingTail
            b.alignment = .left
            b.font = StowTheme.Font.control
            b.toolTip = "\(link.title)\n\(link.url)"
            if let path = link.faviconPath, let image = NSImage(contentsOfFile: path) {
                image.size = NSSize(width: 14, height: 14)
                b.image = image
            } else {
                b.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            }
            addSubview(b)
            return b
        }
        applyColors()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = resolvedCGColor(colors.surface)
        layer?.borderColor = resolvedCGColor(colors.stroke)
        chip.attributedTitle = NSAttributedString(string: name, attributes: [.foregroundColor: colors.surface, .font: StowTheme.Font.title])
        chip.layer?.backgroundColor = resolvedCGColor(colors.inkPrimary)
        for b in tabButtons {
            b.contentTintColor = colors.inkPrimary
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [.foregroundColor: colors.inkPrimary, .font: StowTheme.Font.control, .paragraphStyle: style])
        }
        moreButton.contentTintColor = colors.inkPrimary
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let chipWidth = min(140, chip.intrinsicContentSize.width + 16)
        chip.frame = NSRect(x: 4, y: 4, width: chipWidth, height: h - 8)
        var x = chip.frame.maxX + 6
        let moreWidth: CGFloat = 24
        let tabWidth: CGFloat = 132
        let available = bounds.width - x - moreWidth - 6
        let fit = max(0, Int(available / tabWidth))
        for (i, b) in tabButtons.enumerated() {
            b.isHidden = i >= fit
            guard i < fit else { continue }
            b.frame = NSRect(x: x, y: 3, width: tabWidth - 4, height: h - 6)
            x += tabWidth
        }
        moreButton.isHidden = tabButtons.count <= fit
        moreButton.frame = NSRect(x: bounds.width - moreWidth - 4, y: 3, width: moreWidth, height: h - 6)
    }

    @objc private func tabTapped(_ sender: NSButton) {
        guard links.indices.contains(sender.tag) else { return }
        onOpen?(links[sender.tag])
    }

    @objc private func showMore() {
        let menu = NSMenu()
        for (i, b) in tabButtons.enumerated() where b.isHidden {
            let item = NSMenuItem(title: links[i].title, action: #selector(menuOpen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.image = b.image
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height), in: moreButton)
    }

    @objc private func menuOpen(_ sender: NSMenuItem) {
        guard links.indices.contains(sender.tag) else { return }
        onOpen?(links[sender.tag])
    }
}
