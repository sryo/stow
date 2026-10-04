import AppKit

/// The flyouts that edit one item, beside the row, tile or rail cell that opened them:
/// the single-field editor (rename, Edit URL, new folder and task names), the due date
/// and the snippet editor. One FlyoutController keeps at most one of them open.
@MainActor
final class ItemFlyouts {
    enum Id: Hashable { case text, dueDate, snippet }

    let controller = FlyoutController()
    private var panels: [Id: FlyoutPanel] = [:]
    /// What a click outside does to each open flyout: the text field saves, the date
    /// cancels, the snippet editor saves.
    private var outsideClick: [Id: () -> Void] = [:]

    init() {
        controller.onOutsideClick = { [weak self] in
            guard let self else { return }
            for id in self.controller.openIds.reversed().compactMap({ $0 as? Id }) {
                if let handler = self.outsideClick[id] { handler() } else { self.close(id) }
            }
        }
    }

    func panel(for id: Id) -> FlyoutPanel {
        if let panel = panels[id] { return panel }
        let panel = FlyoutPanel()
        panels[id] = panel
        return panel
    }

    func isOpen(_ id: Id) -> Bool { controller.isOpen(id: id) }

    /// Shows `content` beside the window, its arrow on `anchor`, and gives it the
    /// keyboard. Returns false when the anchor isn't in a window.
    @discardableResult
    func show(_ id: Id, content: NSView, size: NSSize, from anchor: NSView, topInset: CGFloat = 26,
              onEscape: @escaping () -> Void, onOutsideClick: (() -> Void)? = nil) -> Bool {
        guard let window = anchor.window else { return false }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let panel = panel(for: id)
        outsideClick[id] = onOutsideClick
        controller.show(panel, id: id, content: content, size: size, anchor: rect,
                        edge: .beside(column: window.frame), topInset: min(topInset, size.height - 14),
                        parent: window, onEscape: onEscape)
        panel.makeKey()
        return true
    }

    /// Closes the flyout and hands the keyboard back to the window it came from.
    func close(_ id: Id) {
        guard controller.isOpen(id: id) else { return }
        let parent = panel(for: id).parent
        outsideClick[id] = nil
        controller.close(id: id)
        if !controller.isOpen { parent?.makeKey() }
    }

    func closeAll() {
        for id in controller.openIds.compactMap({ $0 as? Id }) { close(id) }
    }
}

/// One field and Save: rename an item, edit a link's URL, or name a new folder or task.
/// Return saves, Esc cancels, and an empty field never saves. The field follows the
/// workspace editor's name row (FlyoutNameField, ringed while focused).
@MainActor
final class TextFieldFlyout: RailFlippedView, NSTextFieldDelegate {
    static let width: CGFloat = 260

    let field = FlyoutNameField()
    let saveButton = FlyoutButton("Save ↩", style: .primary)
    let cancelButton = FlyoutButton("Cancel")
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField

    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?

    /// `title` is the section header ("Rename", "Edit URL"), `detail` the item it acts
    /// on, shown muted beside it.
    init(title: String, detail: String? = nil, value: String, placeholder: String, monospaced: Bool = false) {
        titleLabel = FlyoutLabel.section(title)
        detailLabel = FlyoutLabel.text(detail ?? "", size: 11, color: FlyoutColors.inkSecondary)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        detailLabel.alignment = .right
        let font = monospaced ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : FlyoutFonts.ui(13, .semibold)
        field.font = font
        field.stringValue = value
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: FlyoutColors.inkSecondary,
        ])
        field.setAccessibilityLabel(placeholder)
        field.delegate = self
        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        for view in [titleLabel, detailLabel, field, cancelButton, saveButton] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static let height: CGFloat = 12 + 16 + 6 + 26 + 12 + 24 + 12

    var preferredSize: NSSize { NSSize(width: Self.width, height: Self.height) }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, w = Self.width - pad * 2
        titleLabel.frame = NSRect(x: pad + 2, y: pad + 2, width: w * 0.45, height: 13)
        detailLabel.frame = NSRect(x: pad + w * 0.45, y: pad + 1, width: w * 0.55 - 2, height: 14)
        field.frame = NSRect(x: pad, y: pad + 16 + 6, width: w, height: 26)
        let y = field.frame.maxY + 12
        let s = saveButton.fittingWidth, c = cancelButton.fittingWidth
        saveButton.frame = NSRect(x: Self.width - pad - s, y: y, width: s, height: 24)
        cancelButton.frame = NSRect(x: saveButton.frame.minX - 6 - c, y: y, width: c, height: 24)
    }

    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var trimmedValue: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    func save() {
        let value = trimmedValue
        guard !value.isEmpty else { return cancel() }
        onSave?(value)
    }

    func cancel() { onCancel?() }

    @objc private func saveTapped() { save() }
    @objc private func cancelTapped() { cancel() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            save()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        return false
    }

    /// Shows a text field flyout beside `anchor`. Save and Cancel close it; a click
    /// outside saves, like Return.
    @discardableResult
    static func present(in flyouts: ItemFlyouts, title: String, detail: String? = nil, value: String,
                        placeholder: String, monospaced: Bool = false, from anchor: NSView,
                        onSave: @escaping (String) -> Void, onCancel: (() -> Void)? = nil) -> TextFieldFlyout? {
        let flyout = TextFieldFlyout(title: title, detail: detail, value: value, placeholder: placeholder, monospaced: monospaced)
        var finished = false
        flyout.onSave = { [weak flyouts] value in
            guard !finished else { return }
            finished = true
            flyouts?.close(.text)
            onSave(value)
        }
        flyout.onCancel = { [weak flyouts] in
            guard !finished else { return }
            finished = true
            flyouts?.close(.text)
            onCancel?()
        }
        guard flyouts.show(.text, content: flyout, size: flyout.preferredSize, from: anchor,
                           onEscape: { [weak flyout] in flyout?.cancel() },
                           onOutsideClick: { [weak flyout] in flyout?.save() }) else { return nil }
        flyout.focusField()
        return flyout
    }
}
