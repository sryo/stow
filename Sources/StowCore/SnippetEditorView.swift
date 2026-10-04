import AppKit

final class SnippetEditorView: NSView {
    private let titleField = NSTextField()
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let languagePopup = NSPopUpButton()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var onSave: ((String, String, String?) -> Void)?

    private static let plainText = "Plain Text"

    init(snippet: Snippet, onSave: @escaping (String, String, String?) -> Void) {
        self.onSave = onSave
        super.init(frame: .zero)
        setupViews()
        titleField.stringValue = snippet.title
        textView.string = snippet.content
        let language = SnippetLanguage.normalized(snippet.language)
        languagePopup.addItems(withTitles: [Self.plainText] + SnippetLanguage.choices(including: language))
        if let language {
            languagePopup.selectItem(withTitle: language)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        // Title field
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.placeholderString = "Title"
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .medium)

        let titleLabel = NSTextField(labelWithString: "Title:")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Language selector
        languagePopup.translatesAutoresizingMaskIntoConstraints = false

        // Text view in scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        // Buttons
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.target = self
        saveButton.action = #selector(handleSave)
        saveButton.keyEquivalent = "\r"

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.keyEquivalent = "\u{1b}"

        let languageLabel = NSTextField(labelWithString: "Language:")
        languageLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(titleField)
        addSubview(languageLabel)
        addSubview(languagePopup)
        addSubview(scrollView)
        addSubview(saveButton)
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            titleField.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleField.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            languageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            languageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),

            languagePopup.leadingAnchor.constraint(equalTo: languageLabel.trailingAnchor, constant: 8),
            languagePopup.centerYAnchor.constraint(equalTo: languageLabel.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: languageLabel.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),

            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            saveButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @objc private func handleSave() {
        let title = titleField.stringValue
        let content = textView.string
        let language = languagePopup.indexOfSelectedItem > 0 ? languagePopup.titleOfSelectedItem : nil
        onSave?(title, content, language)
        window?.close()
    }

    @objc private func handleCancel() {
        window?.close()
    }
}
