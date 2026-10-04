import AppKit

/// The tip beside a resting rail item: a small key-less flyout with a name and a quiet
/// detail line, shown after a short dwell so running the pointer down the column doesn't
/// strobe. Both rails use it in place of system tooltips; it hides when the app resigns
/// and whenever a rail flyout opens (`hide()`).
@MainActor
final class RailTipController {
    struct Tip: Equatable {
        var title: String
        var detail: String?

        /// "Alpha · ⌘1": the tip on one line, for VoiceOver help and `toolTip` readers.
        var text: String { [title, detail].compactMap { $0 }.joined(separator: " · ") }
    }

    /// Runs on each dwell instead of showing the hovered source's tip, for a host that
    /// does more on a dwell (the Settings rail previews the page color). Nil shows the tip.
    var onDwell: ((UUID?) -> Void)?
    private let panel = FlyoutPanel(takesKey: false)
    private let tipView = TileTipView()
    private let dwell: HoverDwell
    private var sources: [UUID: (view: NSView, tip: Tip)] = [:]
    private(set) var shown: Tip?

    init(clock: DwellClock = MainQueueDwellClock()) {
        dwell = HoverDwell(clock: clock)
        panel.showsArrow = false
        panel.cornerRadius = 9
        panel.ignoresMouseEvents = true
        dwell.onPreview = { [weak self] id in self?.dwelled(on: id) }
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Hover

    /// A rail item reports the pointer entering (true) or leaving it, with the tip it shows.
    func hover(_ id: UUID, view: NSView, tip: Tip, inside: Bool) {
        if inside {
            sources[id] = (view, tip)
            dwell.pointerEntered(id)
        } else {
            dwell.pointerExited(id)
            sources[id] = nil
        }
    }

    func pointerEntered(_ id: UUID) { dwell.pointerEntered(id) }
    func pointerExited(_ id: UUID) { dwell.pointerExited(id) }
    /// Keyboard focus dwells at once.
    func focusChanged(_ id: UUID?) { dwell.focusChanged(id) }

    private func dwelled(on id: UUID?) {
        if let onDwell { onDwell(id); return }
        guard let id, let source = sources[id] else { hide(resettingDwell: false); return }
        show(source.tip, from: source.view)
    }

    // MARK: Showing

    /// Shows `tip` beside `anchor`, outside the rail that holds it.
    func show(_ tip: Tip, from anchor: NSView, rail: NSView? = nil) {
        guard let window = anchor.window, window.isVisible, !anchor.isHiddenOrHasHiddenAncestor else { return }
        let column = rail ?? Self.rail(of: anchor)
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let columnRect = window.convertToScreen(column.convert(column.bounds, to: nil))
        show(tip, anchor: anchorRect, column: columnRect, parent: window)
    }

    /// Shows `tip` beside `anchor` (screen coordinates), clear of `column`.
    func show(_ tip: Tip, anchor: NSRect, column: NSRect, parent: NSWindow) {
        tipView.set(tip)
        shown = tip
        panel.present(tipView, size: tipView.fittingSize, anchor: anchor, edge: .beside(column: column),
                      topInset: anchor.height / 2 - 4, parent: parent)
    }

    /// Hides the tip and forgets any pending dwell.
    func hide() { hide(resettingDwell: true) }

    /// Hides the tip but keeps the dwell's state, for a host whose dwell does more.
    func hide(resettingDwell: Bool) {
        if resettingDwell { dwell.reset() }
        shown = nil
        if panel.isVisible { panel.dismiss() }
    }

    @objc private func appResigned() { hide() }

    /// The nearest RailView or SettingsRailView holding `view`, else its window's content.
    private static func rail(of view: NSView) -> NSView {
        var current: NSView? = view
        while let v = current {
            if v is RailView || v is SettingsRailView { return v }
            current = v.superview
        }
        return view.window?.contentView ?? view
    }
}

/// The tip's content: the full name, then a quieter line (items, browser, shortcut).
@MainActor
final class TileTipView: RailFlippedView {
    private let name = FlyoutLabel.text("", size: 12.5, weight: .semibold)
    private let detail = FlyoutLabel.text("", size: 11, color: FlyoutColors.inkSecondary)

    init() {
        super.init(frame: .zero)
        addSubview(name)
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(_ tip: RailTipController.Tip) {
        name.stringValue = tip.title
        detail.stringValue = tip.detail ?? ""
        detail.isHidden = tip.detail == nil
        // Labels inset their text 2pt each side; the tip's text sits 10pt in.
        func width(_ label: NSTextField) -> CGFloat {
            label.isHidden ? 0 : (label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width + 6
        }
        let text = ceil(max(width(name), width(detail)))
        frame.size = NSSize(width: text + 16, height: 6 + 16 + (detail.isHidden ? 0 : 14) + 6)
        name.frame = NSRect(x: 8, y: 6, width: text, height: 16)
        detail.frame = NSRect(x: 8, y: 22, width: text, height: 14)
    }

    override var fittingSize: NSSize { frame.size }
}
