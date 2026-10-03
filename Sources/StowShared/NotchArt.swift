import CoreGraphics
import Foundation

/// Geometry for Notch, the bookmark-ribbon character in Stow's empty states.
///
/// Notch is a ribbon with a dog-eared corner; the V-notch at the bottom doubles as feet.
/// Each scene is a tree of named parts in a 96 × 80 unit space (y grows downward), so
/// macOS (shape layers) and iOS (SwiftUI shapes) draw and animate the same drawing.
/// Strokes are 1 unit; the visible crop is `viewBox`.
public enum NotchArt {
    /// The region of the 96 × 80 canvas the scenes occupy.
    public static let viewBox = CGRect(x: 19.2, y: 30, width: 57.6, height: 48)
    public static let strokeWidth: CGFloat = 1

    /// How a shape is painted, mapped to palette colors by the renderer.
    public enum Role: Sendable {
        /// Open stroke in inkSecondary.
        case line
        /// Paper fill with an inkSecondary outline (Notch's body, cards).
        case body
        /// Hover fill with an inkSecondary outline (props, the dog-ear).
        case shade
        /// MultiSelected fill, no stroke (the shelf plank).
        case plank
        /// inkPrimary fill (eyes).
        case eye
        /// inkPrimary stroke (closed eyes, smile).
        case eyeLine
        /// inkSecondary fill (small dots).
        case dot
        /// Glow fill, no stroke (flashlight beam).
        case glow
    }

    public struct Shape: @unchecked Sendable {
        public let path: CGPath
        public let role: Role
    }

    /// A node that can be animated as a unit around `origin`.
    public struct Part: @unchecked Sendable {
        public let name: String
        public let origin: CGPoint
        public var shapes: [Shape]
        public var children: [Part]
        /// Parts that start hidden and are revealed by a state (smile, landed card, peeking eye).
        public var startsHidden: Bool

        init(_ name: String, origin: CGPoint = .zero, shapes: [Shape] = [], children: [Part] = [], startsHidden: Bool = false) {
            self.name = name
            self.origin = origin
            self.shapes = shapes
            self.children = children
            self.startsHidden = startsHidden
        }
    }

    public enum Scene: Sendable { case waiting, searching, foundInArchive, napping, hello }

    public static func scene(_ scene: Scene) -> Part {
        switch scene {
        case .waiting: return waiting()
        case .searching: return searching(found: false)
        case .foundInArchive: return searching(found: true)
        case .napping: return napping()
        case .hello: return hello()
        }
    }

    // MARK: - Path helpers

    private static func shape(_ role: Role, _ build: (CGMutablePath) -> Void) -> Shape {
        let p = CGMutablePath()
        build(p)
        return Shape(path: p, role: role)
    }

    private static func rect(_ role: Role, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat) -> Shape {
        Shape(path: CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil), role: role)
    }

    private static func ellipse(_ role: Role, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> Shape {
        Shape(path: CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil), role: role)
    }

    private static func line(_ points: [CGPoint]) -> Shape {
        shape(.line) { p in p.addLines(between: points) }
    }

    /// A shallow arc drawn as a quadratic, like SVG `M x,y q dx1,dy1 dx2,dy2`.
    private static func quad(_ role: Role, from: CGPoint, control: CGPoint, to: CGPoint) -> Shape {
        shape(role) { p in
            p.move(to: from)
            p.addQuadCurve(to: to, control: control)
        }
    }

    /// The standing ribbon: rounded top-left, dog-eared top-right, V-notch feet at `bottomY`.
    private static func body(cx: CGFloat, bottomY by: CGFloat) -> Shape {
        let l = cx - 11, r = cx + 11, t = by - 30
        return shape(.body) { p in
            p.move(to: CGPoint(x: l, y: t + 5))
            p.addArc(tangent1End: CGPoint(x: l, y: t), tangent2End: CGPoint(x: l + 5, y: t), radius: 5)
            p.addLine(to: CGPoint(x: r - 6, y: t))
            p.addLine(to: CGPoint(x: r, y: t + 6))
            p.addLine(to: CGPoint(x: r, y: by))
            p.addLine(to: CGPoint(x: cx, y: by - 6))
            p.addLine(to: CGPoint(x: l, y: by))
            p.closeSubpath()
        }
    }

    private static func ear(cx: CGFloat, bottomY by: CGFloat) -> Shape {
        let r = cx + 11, t = by - 30
        return shape(.shade) { p in
            p.addLines(between: [CGPoint(x: r - 6, y: t), CGPoint(x: r - 6, y: t + 6), CGPoint(x: r, y: t + 6)])
            p.closeSubpath()
        }
    }

    private static var plank: Shape { rect(.plank, 18, 74, 60, 3, r: 1.5) }

    /// Open eyes, nested so looking, scaling and blinking compose: look ▸ eyes ▸ blinker.
    private static func eyes(cx: CGFloat, y: CGFloat, dx: CGFloat = 0, ry: CGFloat = 2.1) -> Part {
        let o = CGPoint(x: cx + dx, y: y)
        let blinker = Part("blinker", origin: o, shapes: [
            ellipse(.eye, cx: cx - 3.5 + dx, cy: y, rx: 1.5, ry: ry),
            ellipse(.eye, cx: cx + 3.5 + dx, cy: y, rx: 1.5, ry: ry),
        ])
        return Part("look", origin: o, children: [Part("eyes", origin: o, children: [blinker])])
    }

    /// Smiling closed eyes, shown when an item lands (and on Notch's hello).
    private static func happyEyes(cx: CGFloat, y: CGFloat, hidden: Bool = true) -> Part {
        Part("happy", shapes: [
            quad(.eyeLine, from: CGPoint(x: cx - 5, y: y + 0.9), control: CGPoint(x: cx - 3.5, y: y - 1.2), to: CGPoint(x: cx - 2, y: y + 0.9)),
            quad(.eyeLine, from: CGPoint(x: cx + 2, y: y + 0.9), control: CGPoint(x: cx + 3.5, y: y - 1.2), to: CGPoint(x: cx + 5, y: y + 0.9)),
        ], startsHidden: hidden)
    }

    // MARK: - Scenes

    /// Empty workspace: Notch waits holding an empty tray.
    private static func waiting() -> Part {
        let cx: CGFloat = 48, by: CGFloat = 74
        let fig = Part("fig", origin: CGPoint(x: cx, y: by), shapes: [body(cx: cx, bottomY: by), ear(cx: cx, bottomY: by)], children: [
            eyes(cx: cx, y: by - 19),
            happyEyes(cx: cx, y: by - 19),
            Part("card", origin: CGPoint(x: 55, y: 62), shapes: [
                rect(.body, 50, 59.2, 10, 7, r: 1.6),
                ellipse(.dot, cx: 52.8, cy: 61.6, rx: 1, ry: 1),
            ], startsHidden: true),
            Part("tray", origin: CGPoint(x: 48, y: 65.5), shapes: [shape(.shade) { p in
                p.addLines(between: [CGPoint(x: 33, y: 63), CGPoint(x: 63, y: 63), CGPoint(x: 60.5, y: 68), CGPoint(x: 35.5, y: 68)])
                p.closeSubpath()
            }]),
            Part("armL", origin: CGPoint(x: 37, y: 59), shapes: [line([CGPoint(x: 37, y: 59), CGPoint(x: 34, y: 63)])]),
            Part("armR", origin: CGPoint(x: 59, y: 59), shapes: [line([CGPoint(x: 59, y: 59), CGPoint(x: 62, y: 63)])]),
        ])
        return Part("root", shapes: [plank], children: [fig])
    }

    /// No matches: Notch shines a flashlight on an empty shelf. When `found`, the beam
    /// lands on an archive box instead.
    private static func searching(found: Bool) -> Part {
        let cx: CGFloat = 34, by: CGFloat = 74, hx: CGFloat = 49, hy: CGFloat = 57
        let beamOrigin = CGPoint(x: hx, y: hy)
        let beam = Part("beam", origin: beamOrigin, shapes: [shape(.glow) { p in
            p.addLines(between: [CGPoint(x: 55.2, y: 60.3), CGPoint(x: 53.5, y: 62.6), CGPoint(x: 63, y: 74), CGPoint(x: 76, y: 74)])
            p.closeSubpath()
        }])
        var torchTransform = CGAffineTransform(translationX: hx, y: hy).rotated(by: 40 * .pi / 180).translatedBy(x: -hx, y: -hy)
        let torchPath = CGPath(roundedRect: CGRect(x: hx - 1, y: hy - 2, width: 8, height: 4), cornerWidth: 1.5, cornerHeight: 1.5, transform: &torchTransform)
        let torch = Part("torch", origin: beamOrigin, shapes: [Shape(path: torchPath, role: .shade)])

        var children: [Part] = [beam]
        if found {
            children.append(Part("abox", shapes: [
                rect(.shade, 63.5, 67, 13, 7, r: 1.2),
                line([CGPoint(x: 68, y: 70.5), CGPoint(x: 72, y: 70.5)]),
            ], children: [
                Part("lid", origin: CGPoint(x: 78, y: 66), shapes: [rect(.shade, 62, 63.5, 16, 3.5, r: 1.2)]),
            ]))
        }
        let armL: Part = found
            ? Part("armL", origin: CGPoint(x: 23, y: 59), shapes: [line([CGPoint(x: 23, y: 59), CGPoint(x: 20, y: 63)])])
            : Part("armL", origin: CGPoint(x: 23, y: 59), shapes: [line([CGPoint(x: 23, y: 59), CGPoint(x: 18, y: 54)])])
        children.append(Part("fig", origin: CGPoint(x: cx, y: by), shapes: [
            body(cx: cx, bottomY: by), ear(cx: cx, bottomY: by),
            line([CGPoint(x: 45, y: 59), CGPoint(x: hx, y: hy)]),
        ], children: [
            eyes(cx: cx, y: by - 19, dx: found ? 1.5 : 1, ry: found ? 2.4 : 2.1),
            armL,
        ]))
        children.append(torch)
        return Part("root", shapes: [plank], children: children)
    }

    /// Everything archived: Notch naps on the archive box.
    private static func napping() -> Part {
        let lyingBody = shape(.body) { p in
            p.move(to: CGPoint(x: 37, y: 54))
            p.addArc(tangent1End: CGPoint(x: 32, y: 54), tangent2End: CGPoint(x: 32, y: 49), radius: 5)
            p.addLine(to: CGPoint(x: 32, y: 38))
            p.addLine(to: CGPoint(x: 38, y: 32))
            p.addLine(to: CGPoint(x: 62, y: 32))
            p.addLine(to: CGPoint(x: 56, y: 43))
            p.addLine(to: CGPoint(x: 62, y: 54))
            p.closeSubpath()
        }
        let lyingEar = shape(.shade) { p in
            p.addLines(between: [CGPoint(x: 32, y: 38), CGPoint(x: 38, y: 38), CGPoint(x: 38, y: 32)])
            p.closeSubpath()
        }
        let fig = Part("fig", origin: CGPoint(x: 47, y: 54), shapes: [], children: [
            Part("lid", origin: CGPoint(x: 48, y: 60), shapes: [rect(.shade, 27, 54, 42, 6, r: 2)]),
            Part("sleeper", shapes: [lyingBody, lyingEar, line([CGPoint(x: 44, y: 53.5), CGPoint(x: 45.2, y: 58.5)])]),
            Part("sleepL", shapes: [quad(.eyeLine, from: CGPoint(x: 39.2, y: 42), control: CGPoint(x: 41, y: 43.8), to: CGPoint(x: 42.8, y: 42))]),
            Part("sleepR", shapes: [quad(.eyeLine, from: CGPoint(x: 46.2, y: 42), control: CGPoint(x: 48, y: 43.8), to: CGPoint(x: 49.8, y: 42))]),
            Part("peek", shapes: [ellipse(.eye, cx: 41, cy: 42.8, rx: 1.5, ry: 2.1)], startsHidden: true),
        ])
        let zs = Part("zs", origin: CGPoint(x: 24, y: 35), shapes: [
            line([CGPoint(x: 21, y: 35), CGPoint(x: 24.4, y: 35), CGPoint(x: 21, y: 38.8), CGPoint(x: 24.4, y: 38.8)]),
            line([CGPoint(x: 26, y: 30.6), CGPoint(x: 28.4, y: 30.6), CGPoint(x: 26, y: 33.3), CGPoint(x: 28.4, y: 33.3)]),
        ])
        return Part("root", shapes: [plank, rect(.shade, 30, 60, 36, 14, r: 2), rect(.body, 42, 63.5, 12, 5.5, r: 1.2)], children: [fig, zs])
    }

    /// First launch: Notch waves hello next to its satchel.
    private static func hello() -> Part {
        let cx: CGFloat = 36, by: CGFloat = 74
        let handle = shape(.line) { p in
            p.move(to: CGPoint(x: 59, y: 60))
            p.addLine(to: CGPoint(x: 59, y: 57.5))
            p.addArc(tangent1End: CGPoint(x: 59, y: 55.5), tangent2End: CGPoint(x: 61, y: 55.5), radius: 2)
            p.addLine(to: CGPoint(x: 67, y: 55.5))
            p.addArc(tangent1End: CGPoint(x: 69, y: 55.5), tangent2End: CGPoint(x: 69, y: 57.5), radius: 2)
            p.addLine(to: CGPoint(x: 69, y: 60))
        }
        let flapShape = shape(.shade) { p in
            p.move(to: CGPoint(x: 52, y: 66))
            p.addLine(to: CGPoint(x: 52, y: 63))
            p.addArc(tangent1End: CGPoint(x: 52, y: 60), tangent2End: CGPoint(x: 55, y: 60), radius: 3)
            p.addLine(to: CGPoint(x: 73, y: 60))
            p.addArc(tangent1End: CGPoint(x: 76, y: 60), tangent2End: CGPoint(x: 76, y: 63), radius: 3)
            p.addLine(to: CGPoint(x: 76, y: 66))
            p.closeSubpath()
        }
        let fig = Part("fig", origin: CGPoint(x: cx, y: by), shapes: [body(cx: cx, bottomY: by), ear(cx: cx, bottomY: by)], children: [
            eyes(cx: cx, y: by - 19),
            happyEyes(cx: cx, y: by - 19),
            Part("mouth", shapes: [quad(.eyeLine, from: CGPoint(x: 34, y: 58.7), control: CGPoint(x: 36, y: 60.3), to: CGPoint(x: 38, y: 58.7))]),
            Part("armW", origin: CGPoint(x: 25, y: 59), shapes: [line([CGPoint(x: 25, y: 59), CGPoint(x: 20, y: 52)])]),
            Part("armR", origin: CGPoint(x: 47, y: 59), shapes: [line([CGPoint(x: 47, y: 59), CGPoint(x: 52, y: 63)])]),
        ])
        return Part("root", shapes: [plank], children: [
            Part("card", origin: CGPoint(x: 64, y: 60), shapes: [
                rect(.body, 60.5, 56, 7, 8, r: 1.4),
                ellipse(.dot, cx: 64, cy: 59, rx: 1.1, ry: 1.1),
            ], startsHidden: true),
            Part("handle", shapes: [handle]),
            Part("bag", origin: CGPoint(x: 64, y: 74), shapes: [rect(.shade, 52, 60, 24, 14, r: 3)]),
            Part("flap", origin: CGPoint(x: 76, y: 61), shapes: [flapShape, rect(.body, 62.5, 64.5, 3, 4, r: 0.8)]),
            fig,
        ])
    }
}

extension EmptyStateCopy.Scene {
    public var notchScene: NotchArt.Scene {
        switch self {
        case .waiting: return .waiting
        case .searching: return .searching
        case .foundInArchive: return .foundInArchive
        case .napping: return .napping
        case .hello: return .hello
        }
    }
}
