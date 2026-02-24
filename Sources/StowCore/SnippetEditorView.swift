import AppKit

final class SnippetEditorView: NSView {
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let languagePopup = NSPopUpButton()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var onSave: ((String, String?) -> Void)?

    private static let languages = [
        "Plain Text", "Swift", "Python", "JavaScript", "TypeScript",
        "HTML", "CSS", "JSON", "Bash", "Go", "Rust", "Java", "C", "C++",
        "Ruby", "SQL", "Markdown", "YAML", "XML"
    ]

    init(snippet: Snippet, onSave: @escaping (String, String?) -> Void) {
        self.onSave = onSave
        super.init(frame: .zero)
        setupViews()
        textView.string = snippet.content
        if let language = snippet.language,
           let index = Self.languages.firstIndex(of: language) {
            languagePopup.selectItem(at: index)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        // Language selector
        languagePopup.translatesAutoresizingMaskIntoConstraints = false
        languagePopup.addItems(withTitles: Self.languages)

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

        addSubview(languageLabel)
        addSubview(languagePopup)
        addSubview(scrollView)
        addSubview(saveButton)
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            languageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            languageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),

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
        let content = textView.string
        let selectedLanguage = languagePopup.titleOfSelectedItem
        let language = selectedLanguage == "Plain Text" ? nil : selectedLanguage
        onSave?(content, language)
        window?.close()
    }

    @objc private func handleCancel() {
        window?.close()
    }
}
