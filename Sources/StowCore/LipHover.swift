import AppKit

/// Whether the full-screen Tabline peeks, sampled on a timer. The lip peeks when the
/// pointer rests in or climbs into the zone under the screen's top edge, but not while it
/// comes down from the menu bar; the peek folds once the pointer has been off it for
/// `grace`, so a brief trip past its edge doesn't flicker it.
struct LipHover {
    static let grace: TimeInterval = 0.15
    /// Points per sample the pointer may drop and still count as resting.
    static let restingDrop: CGFloat = 2

    let lipFrame: NSRect
    let peekFrame: NSRect
    private var last: NSPoint?
    private var leftAt: TimeInterval?

    init(lipFrame: NSRect, peekFrame: NSRect) {
        self.lipFrame = lipFrame
        self.peekFrame = peekFrame
    }

    /// From just under the lip up through the notch band to the screen's top edge.
    var hotZone: NSRect { NSRect(x: lipFrame.minX, y: lipFrame.minY - 8, width: lipFrame.width, height: 120) }

    /// Takes a pointer sample (screen coordinates) and returns whether the strip should peek.
    mutating func step(mouse: NSPoint, at time: TimeInterval, peeking: Bool) -> Bool {
        defer { last = mouse }
        if peeking {
            if peekFrame.insetBy(dx: -12, dy: -12).contains(mouse) {
                leftAt = nil
                return true
            }
            let left = leftAt ?? time
            leftAt = left
            if time - left < Self.grace { return true }
            leftAt = nil
            return false
        }
        leftAt = nil
        guard let last, hotZone.contains(mouse) else { return false }
        return mouse.y - last.y >= -Self.restingDrop
    }
}
