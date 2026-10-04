import CoreGraphics

/// Geometry for the rail's items while swiping between workspaces.
enum RailSwipe {
    /// How far a swipe travels per page. The rail's content is far narrower than a
    /// two-finger swipe, so there a page is a typical swipe's length.
    static let railPageWidth: CGFloat = 160

    static func pageWidth(contentWidth: CGFloat, isRail: Bool) -> CGFloat {
        isRail ? max(contentWidth, railPageWidth) : contentWidth
    }

    /// Horizontal offsets for the outgoing and incoming items at swipe progress `delta`
    /// (pages moved, negative going back). The incoming items enter from the side of
    /// `direction`: +1 from the right, -1 from the left.
    static func translations(delta: CGFloat, direction: Int, width: CGFloat) -> (outgoing: CGFloat, incoming: CGFloat) {
        let outgoing = -delta * width
        let incoming = (CGFloat(direction) - delta) * width
        return (outgoing, incoming)
    }

    /// The workspace shown on `page`, or nil for Settings (page 0, which the rail never
    /// shows) and the add-new page.
    static func workspaceIndex(forPage page: Int, workspaceCount: Int) -> Int? {
        let index = page - 1
        return (0..<workspaceCount).contains(index) ? index : nil
    }
}
