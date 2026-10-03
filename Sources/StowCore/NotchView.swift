import AppKit

/// Draws and animates Notch (see `NotchArt`) with shape layers colored from the
/// workspace palette. Every motion is skipped when Reduce Motion is on.
final class NotchView: NSView {
    var colors: StowTheme.Colors = StowTheme.colors(for: .defaultColor()) {
        didSet { applyColors() }
    }

    private(set) var scene: NotchArt.Scene = .waiting
    private let artLayer = CALayer()
    private var parts: [String: CALayer] = [:]
    private var shapes: [(CAShapeLayer, NotchArt.Role)] = []
    private var blinkTimer: Timer?

    private var isOpen = false
    private var isHoveringAction = false

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 96, height: 80) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(artLayer)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Building

    func setScene(_ scene: NotchArt.Scene, animated: Bool) {
        let changed = scene != self.scene || parts.isEmpty
        self.scene = scene
        if changed { rebuild() }
        isOpen = false
        isHoveringAction = false
        applyPose(animated: false)
        if animated { playAppear() }
        scheduleBlink()
    }

    private func rebuild() {
        artLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        parts.removeAll()
        shapes.removeAll()
        let root = NotchArt.scene(scene)
        artLayer.addSublayer(makeLayer(root))
        applyColors()
        needsLayout = true
    }

    private func makeLayer(_ part: NotchArt.Part) -> CALayer {
        let size = CGSize(width: 96, height: 80)
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.anchorPoint = CGPoint(x: part.origin.x / size.width, y: part.origin.y / size.height)
        layer.position = part.origin
        layer.opacity = part.startsHidden ? 0 : 1
        for s in part.shapes {
            let shapeLayer = CAShapeLayer()
            shapeLayer.frame = layer.bounds
            shapeLayer.path = s.path
            shapeLayer.lineWidth = NotchArt.strokeWidth
            shapeLayer.lineCap = .round
            shapeLayer.lineJoin = .round
            layer.addSublayer(shapeLayer)
            shapes.append((shapeLayer, s.role))
        }
        for child in part.children {
            layer.addSublayer(makeLayer(child))
        }
        if parts[part.name] == nil { parts[part.name] = layer }
        return layer
    }

    override func layout() {
        super.layout()
        let box = NotchArt.viewBox
        let scale = min(bounds.width / box.width, bounds.height / box.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        artLayer.bounds = box
        artLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        artLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleBlink()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let line = resolvedCGColor(colors.inkSecondary)
        for (layer, role) in shapes {
            layer.strokeColor = nil
            layer.fillColor = nil
            switch role {
            case .line:
                layer.strokeColor = line
            case .body:
                layer.fillColor = resolvedCGColor(colors.paper)
                layer.strokeColor = line
            case .shade:
                layer.fillColor = resolvedCGColor(colors.hover)
                layer.strokeColor = line
            case .plank:
                layer.fillColor = resolvedCGColor(colors.multiSelected)
            case .eye:
                layer.fillColor = resolvedCGColor(colors.inkPrimary)
            case .eyeLine:
                layer.strokeColor = resolvedCGColor(colors.inkPrimary)
                layer.lineWidth = 0.95
            case .dot:
                layer.fillColor = line
            case .glow:
                // The flashlight clicks off while Clear Search is hovered.
                layer.fillColor = resolvedCGColor(isHoveringAction && scene == .searching ? colors.surface : colors.glow)
            }
        }
        CATransaction.commit()
    }

    // MARK: - Poses

    /// Drag-over: Notch opens its arms to catch the link.
    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        applyPose(animated: true)
    }

    /// The action button is hovered or focused: Notch reacts to what it will do.
    func setHoveringAction(_ hovering: Bool) {
        guard hovering != isHoveringAction else { return }
        isHoveringAction = hovering
        applyPose(animated: true)
        applyColors()
    }

    private func rotation(_ degrees: CGFloat) -> CATransform3D {
        CATransform3DMakeRotation(degrees * .pi / 180, 0, 0, 1)
    }

    private func translation(_ x: CGFloat, _ y: CGFloat) -> CATransform3D {
        CATransform3DMakeTranslation(x, y, 0)
    }

    private func applyPose(animated: Bool) {
        var transforms: [String: CATransform3D] = [:]
        var opacities: [String: Float] = [:]

        switch scene {
        case .waiting where isOpen:
            transforms["tray"] = CATransform3DScale(translation(0, -3), 1.12, 1, 1)
            transforms["armL"] = rotation(45)
            transforms["armR"] = rotation(-45)
        case .waiting where isHoveringAction:
            transforms["look"] = translation(0, 1.2)
            transforms["tray"] = translation(0, -1)
        case .hello where isOpen:
            transforms["armW"] = rotation(-16)
            transforms["armR"] = rotation(-96)
            transforms["flap"] = CATransform3DRotate(translation(0, -2), -9 * .pi / 180, 0, 0, 1)
        case .hello where isHoveringAction:
            transforms["look"] = translation(0, 1.2)
            transforms["flap"] = rotation(-5)
        case .foundInArchive where isHoveringAction:
            transforms["lid"] = CATransform3DRotate(translation(0, -1.5), -7 * .pi / 180, 0, 0, 1)
            transforms["look"] = translation(1, 0)
        case .napping where isHoveringAction:
            opacities["peek"] = 1
            opacities["sleepL"] = 0
            transforms["lid"] = translation(0, -0.5)
        default:
            break
        }
        if isOpen {
            transforms["eyes"] = CATransform3DMakeScale(1.22, 1.22, 1)
            transforms["fig"] = translation(0, -1)
        }

        let animate = animated && !reduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(!animate)
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.3, 1.35, 0.5, 1))
        for name in ["tray", "armL", "armR", "armW", "flap", "look", "lid", "eyes", "fig"] {
            parts[name]?.transform = transforms[name] ?? CATransform3DIdentity
        }
        if scene == .napping {
            parts["peek"]?.opacity = opacities["peek"] ?? 0
            parts["sleepL"]?.opacity = opacities["sleepL"] ?? 1
        }
        CATransaction.commit()
    }

    // MARK: - Motion

    private func add(_ animation: CAAnimation, to name: String, delay: CFTimeInterval = 0) {
        guard let layer = parts[name] else { return }
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        layer.add(animation, forKey: "notch.\(name).\(animation.hash)")
    }

    private func basic(_ keyPath: String, from: Any, duration: CFTimeInterval, spring: Bool = true) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.duration = duration
        a.timingFunction = spring
            ? CAMediaTimingFunction(controlPoints: 0.3, 1.45, 0.5, 1)
            : CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        return a
    }

    /// One short entrance per state, at most 600ms.
    func playAppear() {
        guard !reduceMotion else { return }
        let rise = CATransform3DScale(translation(0, 5), 0.96, 0.96, 1)
        switch scene {
        case .waiting:
            add(basic("transform", from: rise, duration: 0.34), to: "fig")
            add(basic("transform", from: rise, duration: 0.34), to: "tray", delay: 0.06)
        case .searching, .foundInArchive:
            add(basic("transform", from: rise, duration: 0.34), to: "fig")
            add(basic("transform", from: rotation(-34), duration: 0.34, spring: false), to: "beam", delay: 0.08)
            add(basic("transform", from: rotation(-34), duration: 0.34, spring: false), to: "torch", delay: 0.08)
            if scene == .searching {
                add(basic("transform", from: rotation(-98), duration: 0.2), to: "armL", delay: 0.4)
            }
        case .napping:
            add(basic("transform", from: translation(0, -5), duration: 0.26), to: "fig")
            let drift = basic("transform", from: translation(4, 5), duration: 0.6, spring: false)
            let fade = basic("opacity", from: 0, duration: 0.24, spring: false)
            add(drift, to: "zs")
            add(fade, to: "zs")
        case .hello:
            add(basic("transform", from: rise, duration: 0.34), to: "fig")
            let wave = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            wave.values = [0, -22, 14, -16, 0].map { $0 * CGFloat.pi / 180 }
            wave.keyTimes = [0, 0.22, 0.48, 0.74, 1]
            wave.duration = 0.6
            wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            add(wave, to: "armW", delay: 0.1)
        }
    }

    /// A 3pt hop when the action is pressed.
    func hop() {
        guard !reduceMotion else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values = [0, -3, 0]
        a.duration = 0.22
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.6, 0.5, 1)
        add(a, to: "fig")
    }

    /// The first item drops into the tray (or satchel) and Notch's eyes smile.
    /// Calls `completion` once the moment has played (immediately with Reduce Motion).
    func playLanding(completion: @escaping () -> Void) {
        guard scene == .waiting || scene == .hello, !reduceMotion else {
            completion()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        parts["card"]?.opacity = 1
        let drop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        drop.values = [-44, 0]
        drop.duration = 0.28
        drop.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.9, 0.55)
        add(drop, to: "card")
        let dip = CAKeyframeAnimation(keyPath: scene == .waiting ? "transform.translation.y" : "transform.scale.y")
        dip.values = scene == .waiting ? [0, 1.6, 0] : [1, 0.93, 1]
        dip.duration = 0.2
        add(dip, to: scene == .waiting ? "tray" : "bag", delay: 0.26)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.08)
            self?.parts["eyes"]?.opacity = 0
            self?.parts["happy"]?.opacity = 1
            CATransaction.commit()
        }
        // Hold the smile briefly before the empty state goes away.
        let hold = CABasicAnimation(keyPath: "opacity")
        hold.fromValue = 1
        hold.toValue = 1
        hold.duration = 0.62
        artLayer.add(hold, forKey: "notch.hold")
        CATransaction.commit()
    }

    /// Stops in-flight motion, e.g. when the user starts swiping between workspaces.
    func settle() {
        func strip(_ layer: CALayer) {
            layer.removeAllAnimations()
            layer.sublayers?.forEach(strip)
        }
        strip(artLayer)
    }

    private func scheduleBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard window != nil, !reduceMotion, parts["blinker"] != nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 6...9), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isOpen, self.window?.isVisible == true {
                    let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
                    blink.values = [1, 0.1, 1]
                    blink.duration = 0.16
                    self.add(blink, to: "blinker")
                }
                self.scheduleBlink()
            }
        }
    }
}
