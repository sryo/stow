import AppKit
import XCTest
@testable import StowCore
import StowShared

/// How rows, tiles, section labels and the snippet editor render their content:
/// truncation, VoiceOver labels and letter tiles.
@MainActor
final class RowRenderingTests: XCTestCase {
    private func listMetrics(_ mode: ElasticMode) -> ListMetrics {
        var metrics = ListMetrics()
        metrics.mode = mode
        return metrics
    }

    private func row(_ content: NodeRowContent, mode: ElasticMode = .list, width: CGFloat = 121) -> NodeRowView {
        let view = NodeRowView(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        view.configure(content: content, metrics: listMetrics(mode), isSelected: false, showSlotAction: false, onSlotAction: nil)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func lineBreakMode(of string: NSAttributedString) -> NSLineBreakMode? {
        guard string.length > 0 else { return nil }
        return (string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineBreakMode
    }

    // MARK: live-9 · done tasks and section labels truncate on one line

    func testADoneTaskTitleTruncatesInsteadOfWrapping() {
        let content = NodeRowContent(kind: .task(isCompleted: true, dueDate: nil), title: "Book flights for the spring trip",
                                     depth: 0, isArchived: false)
        let view = row(content)
        let field = view.descendants(of: InlineEditableTextField.self).first!.textField
        XCTAssertEqual(lineBreakMode(of: field.attributedStringValue), .byTruncatingTail,
                       "the strikethrough attributed title drops the field's truncating-tail mode, so it wraps onto two lines")
    }

    func testADoneTaskTileTitleTruncates() {
        let item = NodeTileItem()
        item.loadView()
        let content = NodeRowContent(kind: .task(isCompleted: true, dueDate: nil), title: "Book flights for the spring trip",
                                     depth: 0, isArchived: false)
        item.configure(content: content, metrics: listMetrics(.mosaic), isSelected: false)
        let title = item.view.descendants(of: NSTextField.self).first { $0.stringValue.hasPrefix("Book") }!
        XCTAssertEqual(lineBreakMode(of: title.attributedStringValue), .byTruncatingTail)
    }

    private func header(style: SectionHeaderItem.Style, width: CGFloat) -> (title: NSTextField, meta: NSTextField) {
        let item = SectionHeaderItem()
        item.loadView()
        item.view.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        item.configure(style: style, title: "Tasks", meta: "2 open", symbol: "checkmark.square", isExpanded: false,
                       metrics: listMetrics(style == .countedRow ? .list : .sidebar), horizontalInset: 8)
        item.view.layoutSubtreeIfNeeded()
        let fields = item.view.descendants(of: NSTextField.self)
        return (fields.first { $0.stringValue == "TASKS" }!, fields.first { $0.stringValue == "2 open" }!)
    }

    func testSectionLabelsUseTruncatingTail() {
        let (title, _) = header(style: .label, width: 260)
        XCTAssertEqual(lineBreakMode(of: title.attributedStringValue), .byTruncatingTail)
    }

    func testAtListWidthTheCountHidesBeforeTheLabelTruncates() {
        let (title, meta) = header(style: .countedRow, width: 121)
        // Text cells inset their text 2pt on each side.
        let needed = ceil(title.attributedStringValue.size().width) + 4
        XCTAssertGreaterThanOrEqual(title.frame.width, needed,
                                    "at 121pt TASKS is cut to \(title.frame.width)pt (needs \(needed)) next to \"2 open\"")
        if !meta.isHidden {
            XCTAssertLessThanOrEqual(title.frame.maxX, meta.frame.minX)
        }
    }

    func testAtListWidthTheCountStaysWhenThereIsRoom() {
        let (_, meta) = header(style: .countedRow, width: 200)
        XCTAssertFalse(meta.isHidden)
    }

    // MARK: modes-21 · labels say when a link is open

    func testAListRowSaysWhenItsLinkIsOpen() {
        var content = NodeRowContent(kind: .link(favicon: nil, domain: "github.com"), title: "GitHub", depth: 0, isArchived: false)
        XCTAssertFalse(row(content).accessibilityLabel()?.contains("open in browser") ?? true)
        content.isOpen = true
        XCTAssertTrue(row(content).accessibilityLabel()?.contains("open in browser") ?? false,
                      "label: \(row(content).accessibilityLabel() ?? "nil")")
    }

    func testATileSaysWhenItsLinkIsOpen() {
        let item = NodeTileItem()
        item.loadView()
        var content = NodeRowContent(kind: .link(favicon: nil, domain: "github.com"), title: "GitHub", depth: 0, isArchived: false)
        content.isOpen = true
        item.configure(content: content, metrics: listMetrics(.mosaic), isSelected: false)
        XCTAssertTrue(item.view.accessibilityLabel()?.contains("open in browser") ?? false,
                      "label: \(item.view.accessibilityLabel() ?? "nil")")
    }

    // MARK: patterns-9 · the list falls back to the shared letter tile

    func testAListRowWithoutAFaviconShowsTheSiteLetterTile() {
        let content = NodeRowContent(kind: .link(favicon: nil, domain: "github.com"), title: "GitHub", depth: 0, isArchived: false)
        let view = row(content, mode: .sidebar, width: 260)
        let icon = view.descendants(of: NSImageView.self).first { $0.image != nil && $0.image?.isTemplate == false }
        XCTAssertNotNil(icon, "a link with no favicon draws the generic template \"link\" symbol instead of its letter tile")
    }

    // MARK: live-8 · the snippet editor keeps Shell

    private func editor(language: String?, onSave: @escaping (String?) -> Void = { _ in }) -> (SnippetEditorView, NSPopUpButton) {
        let snippet = Snippet(id: UUID(), title: "curl health check", content: "curl -fsS localhost/health", language: language,
                              createdAt: Date())
        let view = SnippetEditorView(snippet: snippet) { _, _, language in onSave(language) }
        return (view, view.descendants(of: NSPopUpButton.self).first!)
    }

    func testTheEditorSelectsShell() {
        let (_, popup) = editor(language: "Shell")
        XCTAssertEqual(popup.titleOfSelectedItem, "Shell")
    }

    func testSavingWithoutChangesKeepsShell() {
        var saved: String?? = .none
        let (view, _) = editor(language: "Shell") { saved = .some($0) }
        view.descendants(of: NSButton.self).first { $0.title == "Save" }!.performClick(nil)
        XCTAssertEqual(saved, .some("Shell"))
    }

    func testBashOpensAsShell() {
        let (_, popup) = editor(language: "Bash")
        XCTAssertEqual(popup.titleOfSelectedItem, "Shell")
    }

    func testAnUnknownLanguageStaysSelectable() {
        var saved: String?? = .none
        let (view, popup) = editor(language: "Elixir") { saved = .some($0) }
        XCTAssertEqual(popup.titleOfSelectedItem, "Elixir")
        view.descendants(of: NSButton.self).first { $0.title == "Save" }!.performClick(nil)
        XCTAssertEqual(saved, .some("Elixir"))
    }

    func testNoLanguageIsPlainText() {
        var saved: String?? = .none
        let (view, popup) = editor(language: nil) { saved = .some($0) }
        XCTAssertEqual(popup.titleOfSelectedItem, "Plain Text")
        view.descendants(of: NSButton.self).first { $0.title == "Save" }!.performClick(nil)
        XCTAssertEqual(saved, .some(nil))
    }
}
