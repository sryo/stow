import AppKit
import QuartzCore

/// The picture on a "Where Stow lives" card, drawn in a 120×80 space and scaled to fit:
/// a teal Stow, a white browser and a violet "other app". Floating: the other app slides
/// over Stow. On top: it slides under Stow, which casts a shadow. Attached: the browser
/// moves and shrinks and Stow (a side panel or the Tabline strip) moves with it, while a
/// cursor drags it.
///
/// While `isAnimating`, the story loops (4.6s, starting from the frame it rests on);
/// otherwise it holds the key frame that explains the mode (2.2s in).
@MainActor
final class PlacementIllustration: NSView {
    static let viewBox = NSSize(width: 120, height: 80)
    static let loopDuration: CFTimeInterval = 4.6
    static let keyFrameTime: CFTimeInterval = 2.2

    var mode: AppWindowMode = .floating { didSet { if mode != oldValue { rebuild() } } }
    var edge: BrowserDock = .left { didSet { if edge != oldValue { rebuild() } } }
    /// Attached without Accessibility: Stow drawn as a dashed amber outline with a gap.
    var isWaiting = false { didSet { if isWaiting != oldValue { rebuild() } } }
    var isAnimating = false { didSet { if isAnimating != oldValue { applyMotion() } } }

    private let art = CALayer()
    private let hairline = CAShapeLayer()
    /// The moving parts: the other app (`intr`), the attached group (`glue`), the cursor (`cur`).
    private var intruder: CALayer?
    private var glue: CALayer?
    private var cursor: CALayer?
    private(set) var intruderAnimation: CAKeyframeAnimation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .circular
        layer?.masksToBounds = true
        art.anchorPoint = .zero
        art.bounds = NSRect(origin: .zero, size: Self.viewBox)
        art.isGeometryFlipped = false
        layer?.addSublayer(art)
        hairline.fillColor = nil
        hairline.lineWidth = 0.5
        layer?.addSublayer(hairline)
        setAccessibilityElement(false)
        rebuild()
    }

    convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 72, height: 48)) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = bounds.width / Self.viewBox.width
        art.transform = CATransform3DMakeScale(scale, bounds.height / Self.viewBox.height, 1)
        art.position = .zero
        // The design's inset 0.5px hairline in --c-line.
        hairline.frame = bounds
        hairline.path = CGPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), cornerWidth: 6.75, cornerHeight: 6.75, transform: nil)
        CATransaction.commit()
    }

    /// The hairline's color; the card sets it from its surface.
    var hairlineColor: NSColor = .clear { didSet { refreshColors() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMotion()
    }

    private func refreshColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hairline.strokeColor = placementCG(hairlineColor)
        CATransaction.commit()
    }

    // MARK: Building

    private func cg(_ color: NSColor) -> CGColor { placementCG(color) }

    private func shape(_ path: CGPath, fill: NSColor?, stroke: NSColor? = nil, lineWidth: CGFloat = 0.5,
                       dash: [NSNumber]? = nil, opacity: Float = 1) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = fill.map(cg)
        layer.strokeColor = stroke.map(cg)
        layer.lineWidth = stroke == nil ? 0 : lineWidth
        layer.lineDashPattern = dash
        layer.opacity = opacity
        return layer
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        let r = min(r, w / 2, h / 2)
        return CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// A layer covering the whole 120×80 space, to group shapes that move together.
    private func group() -> CALayer {
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.bounds = CGRect(origin: .zero, size: Self.viewBox)
        layer.position = .zero
        return layer
    }

    private func addBrowser(_ to: CALayer, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
        to.addSublayer(shape(rect(x, y, w, h, 3), fill: PlacementColors.browser, stroke: PlacementColors.edge))
        let bar = CGMutablePath()
        bar.move(to: CGPoint(x: x, y: y + 3))
        bar.addArc(tangent1End: CGPoint(x: x, y: y), tangent2End: CGPoint(x: x + 3, y: y), radius: 3)
        bar.addLine(to: CGPoint(x: x + w - 3, y: y))
        bar.addArc(tangent1End: CGPoint(x: x + w, y: y), tangent2End: CGPoint(x: x + w, y: y + 3), radius: 3)
        bar.addLine(to: CGPoint(x: x + w, y: y + 7))
        bar.addLine(to: CGPoint(x: x, y: y + 7))
        bar.closeSubpath()
        to.addSublayer(shape(bar, fill: PlacementColors.bar))
        for i in 0..<3 {
            let cx = x + 3.5 + CGFloat(i) * 3.4
            to.addSublayer(shape(CGPath(ellipseIn: CGRect(x: cx - 1.1, y: y + 3.5 - 1.1, width: 2.2, height: 2.2), transform: nil),
                                 fill: PlacementColors.edge))
        }
        let widths: [CGFloat] = [0.62, 0.8, 0.5, 0.72, 0.4]
        for i in 0..<5 where y + 12 + CGFloat(i) * 6 < y + h - 3 {
            to.addSublayer(shape(rect(x + 5, y + 12 + CGFloat(i) * 6, (w - 10) * widths[i], 2.4, 1.2), fill: PlacementColors.textLine))
        }
    }

    private func addPanel(_ to: CALayer, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, lift: Bool = false, warn: Bool = false) {
        if lift {
            to.addSublayer(shape(rect(x + 1, y + 2, w, h, 3), fill: .black, opacity: 0.16))
        }
        if warn {
            to.addSublayer(shape(rect(x, y, w, h, 3), fill: nil, stroke: PlacementColors.warning, lineWidth: 0.9, dash: [2, 1.5]))
        } else {
            to.addSublayer(shape(rect(x, y, w, h, 3), fill: PlacementColors.stow, stroke: PlacementColors.edge))
        }
        for i in 0..<6 where y + 6 + CGFloat(i) * 7 < y + h - 4 {
            let row = CGFloat(i) * 7
            to.addSublayer(shape(rect(x + 3, y + 5 + row, 3.4, 3.4, 0.9), fill: PlacementColors.stowInk, opacity: warn ? 0.5 : 1))
            to.addSublayer(shape(rect(x + 8.5, y + 6 + row, (w - 12) * (i % 2 == 1 ? 0.6 : 0.85), 1.6, 0.8),
                                 fill: PlacementColors.stowInk, opacity: warn ? 0.35 : 0.7))
        }
    }

    private func addStrip(_ to: CALayer, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, warn: Bool = false) {
        if warn {
            to.addSublayer(shape(rect(x, y, w, h, 2), fill: nil, stroke: PlacementColors.warning, lineWidth: 0.9, dash: [2, 1.5]))
        } else {
            to.addSublayer(shape(rect(x, y, w, h, 2), fill: PlacementColors.stow, stroke: PlacementColors.edge))
        }
        let count = Int(floor((w - 4) / 9))
        for i in 0..<count {
            to.addSublayer(shape(rect(x + 3 + CGFloat(i) * 9, y + h / 2 - 1.8, i == 1 ? 7 : 3.6, 3.6, 0.9),
                                 fill: PlacementColors.stowInk, opacity: warn ? 0.4 : (i == 1 ? 1 : 0.75)))
        }
    }

    private func makeIntruder() -> CALayer {
        let layer = group()
        layer.addSublayer(shape(rect(5, 26, 48, 38, 3), fill: PlacementColors.intruder, stroke: PlacementColors.edge))
        layer.addSublayer(shape(rect(5, 26, 48, 6, 3), fill: PlacementColors.intruder2))
        layer.addSublayer(shape(CGPath(ellipseIn: CGRect(x: 23, y: 40, width: 12, height: 12), transform: nil),
                                fill: PlacementColors.intruder2, opacity: 0.8))
        layer.addSublayer(shape(rect(24, 54, 10, 3, 1.5), fill: PlacementColors.intruder2, opacity: 0.8))
        return layer
    }

    private func makeCursor(_ x: CGFloat, _ y: CGFloat) -> CAShapeLayer {
        let path = CGMutablePath()
        var p = CGPoint(x: x, y: y)
        path.move(to: p)
        for (dx, dy) in [(0, 7.5), (2, -1.9), (1.4, 3.2), (1.3, -0.6), (-1.4, -3.1), (2.8, -0.2)] as [(CGFloat, CGFloat)] {
            p = CGPoint(x: p.x + dx, y: p.y + dy)
            path.addLine(to: p)
        }
        path.closeSubpath()
        return shape(path, fill: PlacementColors.cursor, stroke: PlacementColors.browser)
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.sublayers?.forEach { $0.removeFromSuperlayer() }
        intruder = nil
        glue = nil
        cursor = nil
        // The flipped view's layer already puts y downward for sublayers.
        art.addSublayer(shape(CGPath(rect: CGRect(origin: .zero, size: Self.viewBox), transform: nil), fill: PlacementColors.wall))
        let hill = CGMutablePath()
        hill.move(to: CGPoint(x: 0, y: 80))
        hill.addCurve(to: CGPoint(x: 120, y: 40), control1: CGPoint(x: 40, y: 52), control2: CGPoint(x: 80, y: 70))
        hill.addLine(to: CGPoint(x: 120, y: 80))
        hill.closeSubpath()
        art.addSublayer(shape(hill, fill: PlacementColors.wall2, opacity: 0.8))

        switch mode {
        case .floating, .onTop:
            addBrowser(art, 46, 12, 64, 54)
            let other = makeIntruder()
            if mode == .floating {
                addPanel(art, 14, 12, 24, 54)
                art.addSublayer(other)
            } else {
                art.addSublayer(other)
                addPanel(art, 14, 12, 24, 54, lift: true)
            }
            intruder = other
        case .attached:
            let gap: CGFloat = isWaiting ? 5 : 0
            let moving = group()
            // transform-origin 60px 14px
            moving.anchorPoint = CGPoint(x: 60 / Self.viewBox.width, y: 14 / Self.viewBox.height)
            moving.position = CGPoint(x: 60, y: 14)
            let pointer: CAShapeLayer
            switch edge {
            case .right:
                addBrowser(moving, 14, 12, 62, 56)
                addPanel(moving, 76 + gap, 12, 22, 56, warn: isWaiting)
                pointer = makeCursor(44, 14)
            case .top:
                addStrip(moving, 20, 10 - gap, 80, 8, warn: isWaiting)
                addBrowser(moving, 20, 18, 80, 52)
                pointer = makeCursor(58, 20)
            case .bottom:
                addBrowser(moving, 20, 10, 80, 52)
                addStrip(moving, 20, 62 + gap, 80, 8, warn: isWaiting)
                pointer = makeCursor(58, 12)
            case .left, .none:
                addPanel(moving, 22 - gap, 12, 22, 56, warn: isWaiting)
                addBrowser(moving, 44, 12, 62, 56)
                pointer = makeCursor(76, 14)
            }
            moving.addSublayer(pointer)
            art.addSublayer(moving)
            glue = moving
            cursor = pointer
        }
        refreshColors()
        CATransaction.commit()
        applyMotion()
    }

    // MARK: Motion

    private static let intruderTimes: [NSNumber] = [0, 0.12, 0.34, 0.64, 0.86, 1]
    private static let intruderValues: [CGFloat] = [86, 86, 0, 0, 86, 86]
    private static let glueTimes: [NSNumber] = [0, 0.12, 0.36, 0.64, 0.88, 1]
    private static let glueProgress: [CGFloat] = [0, 0, 1, 1, 0, 0]
    private static let cursorTimes: [NSNumber] = [0, 0.08, 0.12, 0.88, 0.94, 1]
    private static let cursorValues: [CGFloat] = [0, 0, 1, 1, 0, 0]

    /// translate(-8, 5) scale(0.84) about (60, 14), `progress` of the way.
    private static func glueTransform(_ progress: CGFloat) -> CATransform3D {
        let scale = 1 - 0.16 * progress
        return CATransform3DScale(CATransform3DMakeTranslation(-8 * progress, 5 * progress, 0), scale, scale, 1)
    }

    /// CSS ease-in-out, cubic-bezier(0.42, 0, 0.58, 1), at `x` in 0…1.
    static func easeInOut(_ x: CGFloat) -> CGFloat {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        func bezier(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var lo: CGFloat = 0, hi: CGFloat = 1, t = x
        for _ in 0..<40 {
            t = (lo + hi) / 2
            if bezier(t, 0.42, 0.58) < x { lo = t } else { hi = t }
        }
        return bezier(t, 0, 1)
    }

    private static func value(at time: CFTimeInterval, times: [NSNumber], values: [CGFloat]) -> CGFloat {
        let x = CGFloat(time.truncatingRemainder(dividingBy: loopDuration) / loopDuration)
        for i in 1..<times.count {
            let a = CGFloat(truncating: times[i - 1]), b = CGFloat(truncating: times[i])
            guard x <= b else { continue }
            let p = b > a ? easeInOut((x - a) / (b - a)) : 1
            return values[i - 1] + (values[i] - values[i - 1]) * p
        }
        return values.last ?? 0
    }

    /// The other app's offset along x, `time` seconds into the loop.
    static func intruderOffset(at time: CFTimeInterval) -> CGFloat {
        value(at: time, times: intruderTimes, values: intruderValues)
    }

    static func glue(at time: CFTimeInterval) -> (tx: CGFloat, ty: CGFloat, scale: CGFloat) {
        let p = value(at: time, times: glueTimes, values: glueProgress)
        return (-8 * p, 5 * p, 1 - 0.16 * p)
    }

    static func cursorOpacity(at time: CFTimeInterval) -> CGFloat {
        value(at: time, times: cursorTimes, values: cursorValues)
    }

    private static func loop(_ keyPath: String, values: [Any], times: [NSNumber]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1), count: times.count - 1)
        animation.calculationMode = .linear
        animation.duration = loopDuration
        animation.repeatCount = .infinity
        animation.timeOffset = keyFrameTime
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// Whether every moving part sits on the key frame with no loop running.
    var showsKeyFrame: Bool {
        guard runningAnimationKeys.isEmpty else { return false }
        if let intruder, abs(intruder.transform.m41) > 0.001 { return false }
        if let glue, !CATransform3DEqualToTransform(glue.transform, Self.glueTransform(1)) { return false }
        if let cursor, cursor.opacity != 1 { return false }
        return true
    }

    var runningAnimationKeys: [String] {
        [intruder, glue, cursor].compactMap { $0?.animationKeys() }.flatMap { $0 }
    }

    private func applyMotion() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [intruder, glue, cursor] { part?.removeAllAnimations() }
        intruderAnimation = nil
        // Rest on the key frame; a running loop draws over it.
        intruder?.transform = CATransform3DIdentity
        glue?.transform = Self.glueTransform(1)
        cursor?.opacity = 1
        if isAnimating, window != nil {
            if let intruder {
                let animation = Self.loop("transform.translation.x", values: Self.intruderValues, times: Self.intruderTimes)
                intruder.add(animation, forKey: "intr")
                intruderAnimation = animation
            }
            if let glue {
                glue.add(Self.loop("transform", values: Self.glueProgress.map { NSValue(caTransform3D: Self.glueTransform($0)) },
                                   times: Self.glueTimes), forKey: "glue")
            }
            if let cursor {
                cursor.add(Self.loop("opacity", values: Self.cursorValues, times: Self.cursorTimes), forKey: "cur")
            }
        }
        CATransaction.commit()
    }
}
