import AppKit

/// Share…: the workspace's share link in a card pushed beside the workspace editor, on the
/// editor's own flyout stack, so it's a child of the window it came from and always in
/// front of it. The name, the link (selectable, cut in the middle), Copy link with a
/// "Copied" beat, and Open share page.
@MainActor
final class ShareCardView: RailFlippedView {
    static let width: CGFloat = 276

    private(set) var link = ""
    private(set) var workspaceName = ""
    /// Opens the share page; replaceable in tests.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private let title = FlyoutLabel.section("Share")
    private let nameLabel = FlyoutLabel.text("", size: 14, weight: .semibold)
    private let explanation = FlyoutLabel.wrapping("Anyone with the link can view this workspace and import it.", size: 11)
    private let linkBox = NSView()
    private let linkField = NSTextField(labelWithString: "")
    let copyButton = FlyoutButton("Copy link", style: .primary)
    let openButton = FlyoutButton("Open share page")
    private var copiedReset: DispatchWorkItem?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        for view in [title, nameLabel, explanation, linkBox, copyButton, openButton] as [NSView] { addSubview(view) }
        nameLabel.lineBreakMode = .byTruncatingTail
        linkBox.wantsLayer = true
        linkBox.layer?.cornerRadius = 7
        linkBox.layer?.cornerCurve = .continuous
        linkField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        linkField.textColor = FlyoutColors.ink
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.isSelectable = true
        linkField.setAccessibilityLabel("Share link")
        linkBox.addSubview(linkField)
        copyButton.target = self
        copyButton.action = #selector(copyLink)
        openButton.target = self
        openButton.action = #selector(openPage)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static let height: CGFloat = 12 + 13 + 6 + 18 + 4 + 30 + 10 + 28 + 12 + 24 + 12

    func configure(link: String, workspaceName: String) {
        self.link = link
        self.workspaceName = workspaceName
        nameLabel.stringValue = workspaceName.isEmpty ? "Untitled" : workspaceName
        linkField.stringValue = link
        linkField.toolTip = link
        copiedReset?.cancel()
        copyButton.title = "Copy link"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, w = Self.width - pad * 2
        var y = pad
        title.frame = NSRect(x: pad + 2, y: y, width: w, height: 13)
        y += 13 + 6
        nameLabel.frame = NSRect(x: pad, y: y, width: w, height: 18)
        y += 18 + 4
        explanation.frame = NSRect(x: pad + 2, y: y, width: w - 2, height: 30)
        y += 30 + 10
        linkBox.frame = NSRect(x: pad, y: y, width: w, height: 28)
        let h = linkField.intrinsicContentSize.height
        linkField.frame = NSRect(x: 8, y: (28 - h) / 2, width: w - 16, height: h)
        y += 28 + 12
        let copy = copyButton.fittingWidth, open = openButton.fittingWidth
        copyButton.frame = NSRect(x: pad, y: y, width: copy, height: 24)
        openButton.frame = NSRect(x: pad + copy + 6, y: y, width: open, height: 24)
    }

    private func applyColors() {
        linkBox.layer?.backgroundColor = flyoutCG(FlyoutColors.field)
        explanation.textColor = FlyoutColors.inkSecondary
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        copyButton.title = "Copied"
        NSAccessibility.post(element: copyButton, notification: .announcementRequested,
                             userInfo: [.announcement: "Link copied"])
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.copyButton.title = "Copy link" }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
        needsLayout = true
    }

    @objc private func openPage() {
        guard let url = URL(string: link) else { return }
        openURL(url)
    }
}
