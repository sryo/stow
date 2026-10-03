#if canImport(SwiftUI)
import SwiftUI

extension StowTheme.Colors {
    public var surfaceColor: Color { Color(surface) }
    public var ink: Color { Color(inkPrimary) }
    public var inkSoft: Color { Color(inkSecondary) }
    public var guideColor: Color { Color(guide) }
    public var strokeColor: Color { Color(stroke) }
    public var accentColor: Color { Color(accent) }
    public var overdueColor: Color { Color(overdue) }
    public var hoverColor: Color { Color(hover) }
    public var selectionColor: Color { Color(selectionFill) }

    public static var actionPrimaryColor: Color { Color(actionPrimary) }
    public static var actionArchiveColor: Color { Color(actionArchive) }
    public static var actionDeleteColor: Color { Color(actionDelete) }
}

private struct StowColorsKey: EnvironmentKey {
    static let defaultValue = StowTheme.colors(for: .defaultColor())
}

extension EnvironmentValues {
    /// The palette for the workspace being drawn.
    public var stowColors: StowTheme.Colors {
        get { self[StowColorsKey.self] }
        set { self[StowColorsKey.self] = newValue }
    }
}
#endif

#if canImport(SwiftUI)
/// Notch drawn with SwiftUI from the shared `NotchArt` geometry and the palette.
public struct NotchIllustration: View {
    let scene: NotchArt.Scene
    @Environment(\.stowColors) private var colors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    public init(scene: NotchArt.Scene) {
        self.scene = scene
    }

    public var body: some View {
        let palette = colors.palette(colorScheme == .dark ? .dark : .light)
        Canvas { context, size in
            let box = NotchArt.viewBox
            let scale = min(size.width / box.width, size.height / box.height)
            context.translateBy(x: (size.width - box.width * scale) / 2, y: (size.height - box.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            Self.draw(NotchArt.scene(scene), in: &context, palette: palette)
        }
        .frame(width: 96, height: 80)
        .offset(y: hasAppeared || reduceMotion ? 0 : 5)
        .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.96, anchor: .bottom)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) { hasAppeared = true }
        }
        .accessibilityHidden(true)
    }

    private static func draw(_ part: NotchArt.Part, in context: inout GraphicsContext, palette p: StowTheme.Palette) {
        guard !part.startsHidden else { return }
        let line = Color(p.inkSecondary.platformColor)
        let stroke = StrokeStyle(lineWidth: NotchArt.strokeWidth, lineCap: .round, lineJoin: .round)
        for shape in part.shapes {
            let path = Path(shape.path)
            switch shape.role {
            case .line:
                context.stroke(path, with: .color(line), style: stroke)
            case .body:
                context.fill(path, with: .color(Color(p.paper.platformColor)))
                context.stroke(path, with: .color(line), style: stroke)
            case .shade:
                context.fill(path, with: .color(Color(p.hover.platformColor)))
                context.stroke(path, with: .color(line), style: stroke)
            case .plank:
                context.fill(path, with: .color(Color(p.multiSelected.platformColor)))
            case .eye:
                context.fill(path, with: .color(Color(p.inkPrimary.platformColor)))
            case .eyeLine:
                context.stroke(path, with: .color(Color(p.inkPrimary.platformColor)), style: StrokeStyle(lineWidth: 0.95, lineCap: .round))
            case .dot:
                context.fill(path, with: .color(line))
            case .glow:
                context.fill(path, with: .color(Color(p.glow.platformColor)))
            }
        }
        for child in part.children {
            draw(child, in: &context, palette: p)
        }
    }
}
#endif
