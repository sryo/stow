import AppKit

/// Colors and controls for the flyouts beside the rail (the workspace editor, the app
/// sheet and the tile tip), following the concept's popover tokens.
@MainActor
enum FlyoutColors {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    static let background = dynamic(hex(0xFFFFFF), hex(0x24272B))
    static let ink = dynamic(hex(0x16191C), hex(0xEEF0F2))
    static let inkSecondary = dynamic(hex(0x5B6066), hex(0x9AA1A8))
    static let field = dynamic(NSColor(white: 0, alpha: 0.06), NSColor(white: 1, alpha: 0.08))
    static let line = dynamic(hex(0x14181C, 0.11), NSColor(white: 1, alpha: 0.1))
    static let hover = dynamic(hex(0xEFEDE8), hex(0x2E3236))
    static let segmentOn = dynamic(hex(0xFFFFFF), hex(0x3A3F44))
    static let danger = dynamic(hex(0xB42318), hex(0xFF8A7A))
    static let warning = dynamic(hex(0xB4560A), hex(0xF0A35E))
    /// Tile edges: a dark hairline in light mode, a light one in dark mode.
    static let tileEdge = dynamic(NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0.14))
    static let recording = hex(0x2F7FD8)
}

@MainActor
enum FlyoutFonts {
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}

extension NSView {
    /// Resolves a dynamic color against this view's appearance, for layer colors.
    @MainActor
    func flyoutCG(_ color: NSColor) -> CGColor {
        var result = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }
}

// MARK: - Labels

@MainActor
enum FlyoutLabel {
    /// "COLOR", "ICON"…: 10pt bold capitals, tracked out.
    static func section(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: FlyoutFonts.ui(10, .bold), .kern: 0.7, .foregroundColor: FlyoutColors.inkSecondary,
        ])
        label.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        return label
    }

    static func text(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = FlyoutColors.ink) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = FlyoutFonts.ui(size, weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    static func wrapping(_ text: String, size: CGFloat, color: NSColor = FlyoutColors.inkSecondary) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = FlyoutFonts.ui(size)
        label.textColor = color
        label.isSelectable = false
        return label
    }
}

// MARK: - Base

/// A flyout control: draws itself in `updateLayer`, takes the first click even while the
/// rail's window is key, and runs its action on click, Space or Return.
@MainActor
class FlyoutControl: FocusableControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func handleHoverStateChanged() { needsDisplay = true }
    override func handlePressedStateChanged() { needsDisplay = true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Panels beside the rail are often not key; hover should still show.
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    func applyFocusRing() {
        layer?.borderWidth = isFocused ? SettingsMetrics.focusRingWidth : 0
        layer?.borderColor = flyoutCG(SettingsColors.accent)
    }
}

// MARK: - Button

/// "Open ↩", "Delete…", "Record", "From Arc…": 24pt, radius 7, 12pt semibold.
final class FlyoutButton: FlyoutControl {
    enum Style { case plain, primary, danger, dangerFilled }

    let style: Style
    private let label = NSTextField(labelWithString: "")
    private let height: CGFloat

    var title: String {
        didSet { label.stringValue = title; setAccessibilityLabel(title); invalidateIntrinsicContentSize() }
    }

    init(_ title: String, style: Style = .plain, height: CGFloat = 24, fontSize: CGFloat = 12) {
        self.title = title
        self.style = style
        self.height = height
        super.init(frame: .zero)
        label.stringValue = title
        label.font = FlyoutFonts.ui(fontSize, .semibold)
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(label.intrinsicContentSize.width) + 18, height: height)
    }

    var fittingWidth: CGFloat { intrinsicContentSize.width }

    override func layout() {
        super.layout()
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }

    override func updateLayer() {
        let fill: NSColor
        let ink: NSColor
        switch style {
        case .plain:
            fill = isHovered || isPressed ? FlyoutColors.hover : FlyoutColors.field
            ink = FlyoutColors.ink
        case .primary:
            fill = FlyoutColors.ink.withAlphaComponent(isPressed ? 0.8 : 1)
            ink = FlyoutColors.background
        case .danger:
            fill = isHovered ? FlyoutColors.danger.withAlphaComponent(0.12) : .clear
            ink = FlyoutColors.danger
        case .dangerFilled:
            fill = FlyoutColors.danger.withAlphaComponent(isPressed ? 0.85 : 1)
            ink = .white
        }
        layer?.backgroundColor = flyoutCG(fill)
        label.textColor = isEnabled ? ink : ink.withAlphaComponent(0.4)
        applyFocusRing()
    }
}

// MARK: - Segmented

/// The concept's segmented choice: a field-colored track with 24pt segments, the chosen
/// one raised. Segments may lead with a small view (a page-color swatch, a window glyph).
final class FlyoutSegmented: FlyoutControl {
    struct Segment {
        var title: String
        var leading: NSView?
    }

    private let segments: [Segment]
    private var labels: [NSTextField] = []
    private var pills: [CALayer] = []
    var selectedIndex: Int { didSet { needsDisplay = true; needsLayout = true } }
    var onChange: ((Int) -> Void)?
    private var trackedIndex: Int?

    init(_ segments: [Segment], selected: Int, accessibilityLabel: String) {
        self.segments = segments
        selectedIndex = selected
        super.init(frame: .zero)
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        for segment in segments {
            let pill = CALayer()
            pill.cornerRadius = 6
            pill.cornerCurve = .continuous
            layer?.addSublayer(pill)
            pills.append(pill)
            let label = NSTextField(labelWithString: segment.title)
            label.font = FlyoutFonts.ui(11.5, .medium)
            label.lineBreakMode = .byClipping
            label.setAccessibilityElement(false)
            addSubview(label)
            labels.append(label)
            if let leading = segment.leading { addSubview(leading) }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func accessibilityValue() -> Any? {
        segments.indices.contains(selectedIndex) ? segments[selectedIndex].title : nil
    }

    private func segmentFrame(_ index: Int) -> NSRect {
        let n = CGFloat(segments.count)
        let w = (bounds.width - 4 - 2 * (n - 1)) / n
        return NSRect(x: 2 + CGFloat(index) * (w + 2), y: 2, width: w, height: bounds.height - 4)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, segment) in segments.enumerated() {
            let frame = segmentFrame(i)
            pills[i].frame = frame
            let labelSize = labels[i].intrinsicContentSize
            let leadingWidth = segment.leading.map { $0.frame.width + 4 } ?? 0
            let total = min(frame.width - 2, labelSize.width + leadingWidth)
            var x = frame.midX - total / 2
            if let leading = segment.leading {
                leading.frame.origin = NSPoint(x: round(x), y: round(frame.midY - leading.frame.height / 2))
                x += leadingWidth
            }
            labels[i].frame = NSRect(x: x, y: frame.midY - labelSize.height / 2, width: max(0, total - leadingWidth) + 1, height: labelSize.height)
        }
        CATransaction.commit()
    }

    override func updateLayer() {
        layer?.backgroundColor = flyoutCG(FlyoutColors.field)
        for (i, pill) in pills.enumerated() {
            let on = i == selectedIndex
            pill.backgroundColor = on ? flyoutCG(FlyoutColors.segmentOn) : nil
            pill.shadowOpacity = on ? 0.14 : 0
            pill.shadowRadius = 1.5
            pill.shadowOffset = CGSize(width: 0, height: -1)
            pill.borderWidth = on ? 0.5 : 0
            pill.borderColor = flyoutCG(FlyoutColors.line)
            labels[i].textColor = on ? FlyoutColors.ink : FlyoutColors.inkSecondary
            if let glyph = segments[i].leading as? NSImageView {
                glyph.contentTintColor = on ? FlyoutColors.ink : FlyoutColors.inkSecondary
            }
        }
        alphaValue = isEnabled ? 1 : 0.45
        applyFocusRing()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = segments.indices.first(where: { segmentFrame($0).contains(point) }) else { return }
        select(index)
    }

    override func performAction() {
        select((selectedIndex + 1) % segments.count)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: select(max(0, selectedIndex - 1))
        case 124: select(min(segments.count - 1, selectedIndex + 1))
        default: super.keyDown(with: event)
        }
    }

    private func select(_ index: Int) {
        guard index != selectedIndex else { return }
        selectedIndex = index
        onChange?(index)
    }
}

// MARK: - Pop row

/// A 26pt popup row: optional leading glyph, a title, a quiet detail, and ⌃⌄ at the end.
/// Clicking it asks for a menu, which pops up under it.
final class FlyoutPopRow: FlyoutControl {
    private let glyph = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    var menuProvider: (() -> NSMenu?)?

    init(symbol: String?, accessibilityLabel: String) {
        super.init(frame: .zero)
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        if let symbol {
            glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            addSubview(glyph)
        }
        titleLabel.font = FlyoutFonts.ui(12.5, .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = FlyoutFonts.ui(11)
        detailLabel.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        for v in [titleLabel, detailLabel, chevron, glyph] as [NSView] { v.setAccessibilityElement(false) }
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func set(title: String, detail: String?) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        setAccessibilityValue(detail.map { "\(title), \($0)" } ?? title)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 8
        if glyph.image != nil {
            glyph.frame = NSRect(x: x, y: (bounds.height - 12) / 2, width: 11, height: 12)
            x += 11 + 7
        }
        chevron.frame = NSRect(x: bounds.width - 8 - 9, y: (bounds.height - 12) / 2, width: 9, height: 12)
        let limit = chevron.frame.minX - 6
        let t = titleLabel.intrinsicContentSize
        let titleWidth = min(ceil(t.width) + 4, limit - x)
        titleLabel.frame = NSRect(x: x, y: (bounds.height - t.height) / 2, width: titleWidth, height: t.height)
        x += titleWidth + 7
        let d = detailLabel.intrinsicContentSize
        detailLabel.frame = NSRect(x: x, y: (bounds.height - d.height) / 2 + 0.5, width: max(0, limit - x), height: d.height)
    }

    override func updateLayer() {
        layer?.backgroundColor = flyoutCG(isHovered || isPressed ? FlyoutColors.hover : FlyoutColors.field)
        titleLabel.textColor = isEnabled ? FlyoutColors.ink : FlyoutColors.inkSecondary
        detailLabel.textColor = FlyoutColors.inkSecondary
        glyph.contentTintColor = FlyoutColors.ink
        chevron.contentTintColor = FlyoutColors.ink
        applyFocusRing()
    }

    override func performAction() {
        guard isEnabled, let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 2), in: self)
    }
}

// MARK: - Name field

/// The editor's 26pt name field: 14pt semibold on the field color, ringed in the
/// workspace color while it has focus.
final class FlyoutNameField: NSTextField {
    var ringColor: NSColor = FlyoutColors.ink { didSet { needsDisplay = true } }
    var onFocusChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = FlyoutNameFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = FlyoutFonts.ui(14, .semibold)
        textColor = FlyoutColors.ink
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isFocused: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate as? NSTextField === self
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        refreshLook()
        onFocusChange?(true)
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        refreshLook()
        onFocusChange?(false)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        refreshLook()
    }

    func refreshLook() {
        layer?.backgroundColor = flyoutCG(FlyoutColors.field)
        layer?.borderWidth = isFocused ? 2 : 0
        layer?.borderColor = flyoutCG(ringColor)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLook()
    }
}

/// Insets the text 8pt and centers it vertically in the 26pt field.
private final class FlyoutNameFieldCell: NSTextFieldCell {
    private func inset(_ rect: NSRect) -> NSRect {
        let h = cellSize(forBounds: rect).height
        return NSRect(x: rect.minX + 8, y: rect.minY + (rect.height - h) / 2, width: rect.width - 16, height: h)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { inset(super.drawingRect(forBounds: rect)) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: inset(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
