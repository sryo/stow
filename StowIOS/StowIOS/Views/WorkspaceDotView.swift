import SwiftUI
import UIKit
import StowShared

/// The iPhone's one workspace dot, matching the Mac's WorkspaceDot: filled with
/// `colorId.color`, edged with the settings palette's secondary ink (dark enough for 3:1
/// in both appearances), and ringed when it's the current one.
struct WorkspaceDotView: View {
    let colorId: WorkspaceColorId
    var diameter: CGFloat = 12
    var isCurrent = false

    static let ringOutset: CGFloat = 3.5
    static let gapWidth: CGFloat = 2
    static var edge: UIColor { StowTheme.colors(for: .settingsBackground).inkSecondary }

    var body: some View {
        Circle()
            .fill(Color(colorId.color))
            .overlay(Circle().strokeBorder(Color(Self.edge), lineWidth: 1))
            .frame(width: diameter, height: diameter)
            .padding(isCurrent ? Self.ringOutset : 0)
            .overlay {
                if isCurrent {
                    Circle().strokeBorder(Color(StowTheme.colors(for: .settingsBackground).inkPrimary),
                                          lineWidth: Self.ringOutset - Self.gapWidth)
                }
            }
            .accessibilityHidden(true)
    }

    /// The same dot as an image, for Menu labels, which tint SF Symbols and drop custom views.
    @MainActor
    static func image(_ colorId: WorkspaceColorId, diameter: CGFloat = 12, isCurrent: Bool = false) -> UIImage {
        // Uncurrent dots keep the ring's room so the menu's labels line up.
        let renderer = ImageRenderer(content: WorkspaceDotView(colorId: colorId, diameter: diameter, isCurrent: isCurrent)
            .padding(isCurrent ? 0 : ringOutset))
        renderer.scale = UITraitCollection.current.displayScale
        return (renderer.uiImage ?? UIImage()).withRenderingMode(.alwaysOriginal)
    }
}
