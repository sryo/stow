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
