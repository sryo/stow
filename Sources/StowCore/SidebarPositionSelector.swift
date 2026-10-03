import AppKit

/// A 22pt segmented choice for Settings (Page color, Window, Browser side).
///
/// The track is transparent with a controlEdge outline; the selected segment is a raised
/// thumb inset 1pt with its own controlEdge outline and a semibold label. ←/→ move the
/// selection, and VoiceOver reads it as a radio group.
final class SettingsSegmentedControl: FocusableControl {
    struct Segment {
        var title: String
        /// An optional preview drawn before the title (a glyph or a thumbnail).
        var leadingView: NSView?
        var accessibilityHint: String?

        init(title: String, leadingView: NSView? = nil, accessibilityHint: String? = nil) {
            self.title = title
            self.leadingView = leadingView
            self.accessibilityHint = accessibilityHint
        }
    }

    private struct SegmentViews {
        let label: NSTextField
        let leading: NSView?
    }

    private let segments: [Segment]
    private var views: [SegmentViews] = []
    private let thumbLayer = CALayer()
    private var segmentElements: [SegmentAccessibilityElement] = []
    private let horizontalPadding: CGFloat = 5
    private let leadingGap: CGFloat = 4

    /// When true, segments share the full width equally; otherwise each hugs its content.
    var fillsWidth = false {
        didSet { invalidateIntrinsicContentSize(); needsLayout = true }
    }

    var selectedIndex: Int {
        didSet {
            guard oldValue != selectedIndex else { return }
            needsLayout = true
            needsDisplay = true
            updateLabels()
        }
    }

    /// Called when the user picks a segment (not when `selectedIndex` is set in code).
    var onChange: ((Int) -> Void)?

    override var isEnabled: Bool {
        didSet { needsDisplay = true; updateLabels() }
    }

    init(segments: [Segment], selectedIndex: Int = 0, accessibilityLabel: String) {
        self.segments = segments
        self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = SettingsMetrics.rowRadius
        layer?.addSublayer(thumbLayer)
        thumbLayer.cornerRadius = SettingsMetrics.rowRadius - 1
        thumbLayer.borderWidth = 1
        // The thumb moves instantly; the selection change itself is the feedback.
        thumbLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]

        for segment in segments {
            let label = NSTextField(labelWithString: segment.title)
            label.font = StowTheme.Font.control
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityElement(false)
            addSubview(label)
            if let leading = segment.leadingView {
                leading.setAccessibilityElement(false)
                addSubview(leading)
            }
            views.append(SegmentViews(label: label, leading: segment.leadingView))
        }

        heightAnchor.constraint(equalToConstant: SettingsMetrics.controlHeight).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(accessibilityLabel)
        segmentElements = segments.indices.map { SegmentAccessibilityElement(control: self, index: $0, title: segments[$0].title, hint: segments[$0].accessibilityHint) }
        updateLabels()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    private func contentWidth(of index: Int, withPreviews: Bool = true) -> CGFloat {
        let v = views[index]
        let labelWidth = Self.textWidth(v.label)
        let leadingWidth = v.leading.map { $0.fittingSize.width > 0 ? $0.fittingSize.width : $0.frame.width } ?? 0
        return labelWidth + (v.leading == nil || !withPreviews ? 0 : leadingWidth + leadingGap) + horizontalPadding * 2
    }

    private func totalWidth(withPreviews: Bool) -> CGFloat {
        let widths = segments.indices.map { contentWidth(of: $0, withPreviews: withPreviews) }
        let width = fillsWidth ? (widths.max() ?? 0) * CGFloat(widths.count) : widths.reduce(0, +)
        return width + 2
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: totalWidth(withPreviews: true), height: SettingsMetrics.controlHeight)
    }

    /// The narrowest the control gets before labels truncate: previews dropped.
    var compactWidth: CGFloat { totalWidth(withPreviews: false) }

    /// Previews show only when every segment has room for one.
    private var showsPreviews: Bool {
        guard fillsWidth else { return bounds.width >= totalWidth(withPreviews: true) - 0.5 }
        let segmentWidth = (bounds.width - 2) / CGFloat(max(segments.count, 1))
        return segments.indices.allSatisfy { contentWidth(of: $0) - horizontalPadding * 2 + 4 <= segmentWidth }
    }

    /// The label's drawn width (its cell size; intrinsicContentSize runs a few points short
    /// for frame-positioned labels).
    private static func textWidth(_ label: NSTextField) -> CGFloat {
        ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width)
    }

    private func segmentFrames() -> [NSRect] {
        let inner = bounds.insetBy(dx: 1, dy: 1)
        var frames: [NSRect] = []
        if fillsWidth {
            let w = inner.width / CGFloat(max(segments.count, 1))
            for i in segments.indices {
                frames.append(NSRect(x: inner.minX + CGFloat(i) * w, y: inner.minY, width: w, height: inner.height))
            }
        } else {
            let previews = showsPreviews
            let natural = segments.indices.map { contentWidth(of: $0, withPreviews: previews) }
            let total = natural.reduce(0, +)
            let scale = total > 0 ? min(1, inner.width / total) : 1
            var x = inner.minX
            for w in natural {
                frames.append(NSRect(x: x, y: inner.minY, width: w * scale, height: inner.height))
                x += w * scale
            }
        }
        return frames
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutSegments()
    }

    override func layout() {
        super.layout()
        layoutSegments()
    }

    private func layoutSegments() {
        guard bounds.width > 0 else { return }
        let frames = segmentFrames()
        let previews = showsPreviews
        for (i, frame) in frames.enumerated() {
            let v = views[i]
            let labelSize = NSSize(width: Self.textWidth(v.label), height: v.label.intrinsicContentSize.height)
            let leadingSize = v.leading.map { view -> NSSize in
                let s = view.fittingSize
                return s.width > 0 ? s : view.frame.size
            } ?? .zero
            // Previews give way first when a segment is too narrow for both.
            let showsLeading = v.leading != nil && previews && ceil(labelSize.width) + leadingSize.width + leadingGap + 4 <= frame.width
            v.leading?.isHidden = !showsLeading
            let groupWidth = min(frame.width - 2, ceil(labelSize.width) + (showsLeading ? leadingSize.width + leadingGap : 0))
            var x = frame.midX - groupWidth / 2
            if showsLeading, let leading = v.leading {
                leading.frame = NSRect(x: round(x), y: round(frame.midY - leadingSize.height / 2),
                                       width: leadingSize.width, height: leadingSize.height)
                x += leadingSize.width + leadingGap
            }
            let labelWidth = max(0, frame.maxX - 1 - x)
            v.label.frame = NSRect(x: round(x), y: round(frame.midY - labelSize.height / 2),
                                   width: min(ceil(labelSize.width), labelWidth), height: labelSize.height)
        }
        if frames.indices.contains(selectedIndex) {
            thumbLayer.frame = frames[selectedIndex].insetBy(dx: 1, dy: 1)
        }
        for (i, element) in segmentElements.enumerated() where frames.indices.contains(i) {
            element.setAccessibilityFrameInParentSpace(frames[i])
        }
    }

    // MARK: Drawing

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = isFocused ? SettingsMetrics.focusRingWidth : 1
        layer?.borderColor = (isFocused ? SettingsColors.accent : SettingsColors.edge).cgColor
        thumbLayer.backgroundColor = SettingsColors.raised.cgColor
        thumbLayer.borderColor = SettingsColors.edge.cgColor
        thumbLayer.isHidden = !segments.indices.contains(selectedIndex)
    }

    private func updateLabels() {
        for (i, v) in views.enumerated() {
            let selected = i == selectedIndex
            v.label.font = selected ? .systemFont(ofSize: StowTheme.Font.control.pointSize, weight: .semibold) : StowTheme.Font.control
            v.label.textColor = selected && isEnabled ? SettingsColors.ink : SettingsColors.inkSecondary
            (v.leading as? NSImageView)?.contentTintColor = selected && isEnabled ? SettingsColors.ink : SettingsColors.inkSecondary
        }
        layoutSegments()
        setAccessibilityValue(segments.indices.contains(selectedIndex) ? segments[selectedIndex].title : nil)
        for (i, element) in segmentElements.enumerated() {
            element.setAccessibilityValue(i == selectedIndex ? 1 : 0)
            element.setAccessibilityEnabled(isEnabled)
        }
        needsLayout = true
    }

    override func handleHoverStateChanged() {}

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let index = segmentFrames().firstIndex(where: { $0.contains(point) }) {
            select(index)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: select(max(0, selectedIndex - 1))           // ←
        case 124: select(min(segments.count - 1, selectedIndex + 1)) // →
        case 49, 36, 76: break
        default: super.keyDown(with: event)
        }
    }

    override func performAction() {}

    fileprivate func select(_ index: Int) {
        guard isEnabled, segments.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        onChange?(index)
        sendAction(action, to: target)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? { segmentElements }
}

private final class SegmentAccessibilityElement: NSAccessibilityElement {
    private weak var control: SettingsSegmentedControl?
    private let index: Int

    init(control: SettingsSegmentedControl, index: Int, title: String, hint: String?) {
        self.control = control
        self.index = index
        super.init()
        setAccessibilityParent(control)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityHelp(hint)
    }

    override func accessibilityPerformPress() -> Bool {
        let control = self.control, index = self.index
        MainActor.assumeIsolated { control?.select(index) }
        return true
    }
}

/// A framed page thumbnail for a Page color segment: the last-viewed workspace's page
/// surface in one tint mode, with its dot when the mode is Off.
final class PageThumbnailView: NSView {
    let tint: StowTheme.TintMode
    var colorId: WorkspaceColorId = .defaultColor() {
        didSet { needsDisplay = true }
    }
    private let dotLayer = CALayer()

    init(tint: StowTheme.TintMode) {
        self.tint = tint
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 10))
        wantsLayer = true
        layer?.cornerRadius = 2.5
        layer?.borderWidth = 1
        layer?.addSublayer(dotLayer)
        dotLayer.frame = NSRect(x: 4.5, y: 2.5, width: 5, height: 5)
        dotLayer.cornerRadius = 2.5
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var fittingSize: NSSize { NSSize(width: 14, height: 10) }
    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 10) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let colors = StowTheme.colors(for: colorId, tint: tint)
        layer?.backgroundColor = colors.surface.cgColor
        layer?.borderColor = SettingsColors.edge.cgColor
        dotLayer.isHidden = tint != .off
        dotLayer.backgroundColor = colorId.color.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
