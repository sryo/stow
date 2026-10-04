import AppKit

/// "Share “Research”": the workspace's share link with a Copy button.
@MainActor
final class SharePanel: NSObject {
    private static var open: [SharePanel] = []
    private let panel: NSPanel
    private let url: String
    private let copyButton = NSButton(title: "Copy link", target: nil, action: nil)

    static func show(url: String, workspaceName: String) {
        let share = SharePanel(url: url, workspaceName: workspaceName)
        open.append(share)
        share.panel.center()
        share.panel.makeKeyAndOrderFront(nil)
    }

    private init(url: String, workspaceName: String) {
        self.url = url
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled, .closable],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Share “\(workspaceName)”"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        let label = NSTextField(wrappingLabelWithString: "Anyone with this link can view and import your workspace:")
        let field = NSTextField(string: url)
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.target = self
        copyButton.action = #selector(copyLink)
        for view in [label, field, copyButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            copyButton.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 16),
            copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        panel.contentView = content
        NotificationCenter.default.addObserver(self, selector: #selector(closed), name: NSWindow.willCloseNotification, object: panel)
    }

    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        copyButton.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copyButton.title = "Copy link" }
    }

    @objc private func closed() {
        Self.open.removeAll { $0 === self }
    }
}
