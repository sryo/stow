import AppKit

/// The snippet editor, shown in a flyout beside the snippet's row or the rail: title,
/// language, the code, then Cancel and Save. One instance is reused; `load` swaps in
/// another snippet. Esc cancels; Return in the title saves (in the code it's a newline).
@MainActor
final class SnippetEditorView: RailFlippedView, NSTextFieldDelegate, NSTextViewDelegate {
    static let size = NSSize(width: 360, height: 300)

    private let headerLabel = FlyoutLabel.section("Snippet")
    let titleField = FlyoutNameField()
    let languagePopup = NSPopUpButton()
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    let cancelButton = FlyoutButton("Cancel")
    let saveButton = FlyoutButton("Save", style: .primary)
    var onSave: ((String, String, String?) -> Void)?
    /// Closes the flyout; the presenter sets it.
    var onClose: (() -> Void)?

    private static let plainText = "Plain Text"

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setupViews()
    }

    convenience init(snippet: Snippet, onSave: @escaping (String, String, String?) -> Void) {
        self.init()
        self.onSave = onSave
        load(snippet)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `snippet` in the editor, replacing whatever it held.
    func load(_ snippet: Snippet) {
        titleField.stringValue = snippet.title
        textView.string = snippet.content
        let language = SnippetLanguage.normalized(snippet.language)
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: [Self.plainText] + SnippetLanguage.choices(including: language))
        if let language {
            languagePopup.selectItem(withTitle: language)
        } else {
            languagePopup.selectItem(at: 0)
        }
    }

    var contentText: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    func focusContent() {
        window?.makeFirstResponder(textView)
    }

    private func setupViews() {
        titleField.placeholderAttributedString = NSAttributedString(string: "Title", attributes: [
            .font: FlyoutFonts.ui(14, .semibold), .foregroundColor: FlyoutColors.inkSecondary,
        ])
        titleField.setAccessibilityLabel("Snippet title")
        titleField.delegate = self

        languagePopup.controlSize = .small
        languagePopup.font = FlyoutFonts.ui(11)
        languagePopup.isBordered = false
        languagePopup.setAccessibilityLabel("Language")

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 7
        scrollView.layer?.cornerCurve = .continuous
        scrollView.documentView = textView

        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = FlyoutColors.ink
        textView.insertionPointColor = FlyoutColors.ink
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel("Snippet content")

        saveButton.target = self
        saveButton.action = #selector(handleSave)
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)

        for view in [headerLabel, languagePopup, titleField, scrollView, cancelButton, saveButton] as [NSView] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Edit snippet")
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, w = bounds.width - pad * 2
        headerLabel.frame = NSRect(x: pad + 2, y: pad + 4, width: 120, height: 13)
        languagePopup.frame = NSRect(x: bounds.width - pad - 140, y: pad, width: 140, height: 20)
        titleField.frame = NSRect(x: pad, y: pad + 20 + 6, width: w, height: 26)
        let footerY = bounds.height - pad - 24
        let top = titleField.frame.maxY + 8
        scrollView.frame = NSRect(x: pad, y: top, width: w, height: max(40, footerY - 10 - top))
        scrollView.layer?.backgroundColor = flyoutCG(FlyoutColors.field)
        let s = saveButton.fittingWidth, c = cancelButton.fittingWidth
        saveButton.frame = NSRect(x: bounds.width - pad - s, y: footerY, width: s, height: 24)
        cancelButton.frame = NSRect(x: saveButton.frame.minX - 6 - c, y: footerY, width: c, height: 24)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    func save() {
        let language = languagePopup.indexOfSelectedItem > 0 ? languagePopup.titleOfSelectedItem : nil
        onSave?(titleField.stringValue, textView.string, language)
        onClose?()
    }

    func cancel() {
        onClose?()
    }

    @objc private func handleSave() { save() }
    @objc private func handleCancel() { cancel() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): save(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        default: return false
        }
    }

    /// In the code, Esc cancels rather than completing words.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSResponder.complete(_:)) else {
            return false
        }
        cancel()
        return true
    }
}
