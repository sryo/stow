import Foundation

/// The ribbon color the Dock icon takes from the current workspace.
public enum DockIconTint {

    /// The lighter top of the icon's graphite tile, the surface the ribbon must read against.
    static let tile = StowTheme.RGB(hex: "#2A2A2E")!
    static let minimumContrast = 3.0

    /// The workspace color, lifted toward white until it clears 3:1 on the tile.
    /// `nil` means the bundled icon should be shown instead.
    public static func ribbonColor(for colorId: WorkspaceColorId) -> StowTheme.RGB? {
        if colorId == .settingsBackground { return nil }
        let base = StowTheme.RGB(colorId.color)
        var t = 0.0
        while t < 1 {
            let c = base.mix(.white, t)
            if c.contrast(with: tile) >= minimumContrast { return c }
            t += 0.02
        }
        return .white
    }
}
