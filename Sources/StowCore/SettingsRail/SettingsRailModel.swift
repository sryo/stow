import AppKit

// Settings in the 52pt rail ("workspace-first rail"): the logic behind it, kept free of
// views so it can be tested. Geometry is in the rail's flipped coordinates.

// MARK: - Layout

/// Metrics for the Settings rail. The tile list is a scroll view between the gear (top)
/// and the quiet cell (bottom); tile frames are in that list's coordinates.
enum SettingsRailLayout {
    static let railWidth: CGFloat = 52
    static let gearFrame = NSRect(x: 19, y: 13, width: 14, height: 14)
    static let separatorY: CGFloat = 36
    static let listTop: CGFloat = 46
    static let listBottomInset: CGFloat = 52
    /// The thin rule above the quiet cell, measured from the rail's bottom.
    static let quietSeparatorFromBottom: CGFloat = 48

    static let tileSize: CGFloat = 36
    static let tileX: CGFloat = 8
    static let tileRadius: CGFloat = 11
    /// Tile plus caption.
    static let rowHeight: CGFloat = 51
    static let pitch: CGFloat = 59
    static let captionTop: CGFloat = 38
    static let captionHeight: CGFloat = 12
    static let captionInset: CGFloat = 2
    static var captionFont: NSFont { .systemFont(ofSize: 9.5, weight: .semibold) }

    static func rowFrame(at index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * pitch, width: railWidth, height: rowHeight)
    }

    static func tileFrame(at index: Int) -> NSRect {
        NSRect(x: tileX, y: CGFloat(index) * pitch, width: tileSize, height: tileSize)
    }

    static func captionFrame(at index: Int) -> NSRect {
        NSRect(x: captionInset, y: CGFloat(index) * pitch + captionTop,
               width: railWidth - captionInset * 2, height: captionHeight)
    }

    static func cameFromDotFrame(at index: Int) -> NSRect {
        NSRect(x: 2, y: CGFloat(index) * pitch + 16, width: 4, height: 4)
    }

    static func addTileFrame(count: Int) -> NSRect {
        tileFrame(at: count)
    }

    static func contentHeight(count: Int) -> CGFloat {
        addTileFrame(count: count).maxY
    }

    static func listHeight(railHeight: CGFloat) -> CGFloat {
        max(0, railHeight - listTop - listBottomInset)
    }

    static func quietCellFrame(railHeight: CGFloat) -> NSRect {
        NSRect(x: 11, y: railHeight - 40, width: 30, height: 30)
    }

    static func scrolls(count: Int, railHeight: CGFloat) -> Bool {
        contentHeight(count: count) > listHeight(railHeight: railHeight)
    }

    static func fullyVisibleTileCount(railHeight: CGFloat) -> Int {
        let visible = listHeight(railHeight: railHeight)
        guard visible >= rowHeight else { return 0 }
        return Int(floor((visible - rowHeight) / pitch)) + 1
    }

    static func captionWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: captionFont]).width)
    }

    /// The name cut to the caption's width with a trailing ellipsis.
    static func caption(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = captionFrame(at: 0).width
        guard captionWidth(trimmed) > limit else { return trimmed }
        var chars = Array(trimmed)
        while !chars.isEmpty {
            chars.removeLast()
            let candidate = String(chars).trimmingCharacters(in: .whitespaces) + "…"
            if captionWidth(candidate) <= limit { return candidate }
        }
        return "…"
    }

    // On a workspace page the gear heads the dot column and each 12pt dot sits 18pt
    // below the last; entering Settings grows each dot from here into its tile.
    static let dotPitch: CGFloat = 18

    static func dotCenterY(at index: Int) -> CGFloat {
        gearFrame.minY + dotPitch * CGFloat(index + 1) + 6
    }

    static func dotsSeparatorY(count: Int) -> CGFloat {
        gearFrame.minY + dotPitch * CGFloat(count + 1) + 4
    }
}

// MARK: - Drag to reorder

enum TileReorder {
    static let startThreshold: CGFloat = 4

    static func hasStarted(dy: CGFloat) -> Bool {
        abs(dy) >= startThreshold
    }

    /// The dragged tile's top, kept between just above the first slot and just below the last.
    static func clampedTileTop(_ y: CGFloat, count: Int) -> CGFloat {
        let last = SettingsRailLayout.tileFrame(at: max(0, count - 1)).minY
        return min(max(y, -10), last + 10)
    }

    /// The slot nearest the dragged tile's top: the index it takes once dropped.
    static func targetIndex(tileTop: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let y = clampedTileTop(tileTop, count: count)
        let slot = Int((y / SettingsRailLayout.pitch).rounded(.toNearestOrAwayFromZero))
        return min(max(slot, 0), count - 1)
    }

    static func order<T: Equatable>(_ ids: [T], moving: T, to index: Int) -> [T] {
        var rest = ids.filter { $0 != moving }
        guard rest.count < ids.count else { return ids }
        rest.insert(moving, at: min(max(index, 0), rest.count))
        return rest
    }

    /// The final index to hand to the model, or nil when the tile ends where it started.
    static func move(from: Int, to: Int) -> Int? {
        from == to ? nil : to
    }

    static func dropIndicatorY(to index: Int) -> CGFloat {
        SettingsRailLayout.tileFrame(at: index).minY - 5
    }
}

// MARK: - Navigation

/// Settings is page 0, before the first workspace. Entering remembers the workspace you
/// came from (the 4pt dot), which the gear and Esc take you back to.
struct SettingsRailNavigation {
    enum Destination: Equatable { case settings, workspace(UUID) }
    enum EscapeAction: Equatable { case closeFlyout, leave(UUID), none }

    private(set) var cameFrom: UUID?

    mutating func didEnterSettings(from id: UUID?) {
        cameFrom = id
    }

    func cameFromIndex(in workspaces: [UUID]) -> Int? {
        cameFrom.flatMap { workspaces.firstIndex(of: $0) }
    }

    /// Where leaving Settings goes: the workspace you came from, or the first one if it's gone.
    func returnTarget(in workspaces: [UUID]) -> UUID? {
        if let cameFrom, workspaces.contains(cameFrom) { return cameFrom }
        return workspaces.first
    }

    func gearDestination(isOnSettings: Bool, workspaces: [UUID]) -> Destination {
        guard isOnSettings, let target = returnTarget(in: workspaces) else { return .settings }
        return .workspace(target)
    }

    func escapeAction(isOnSettings: Bool, flyoutOpen: Bool, workspaces: [UUID]) -> EscapeAction {
        guard isOnSettings else { return .none }
        if flyoutOpen { return .closeFlyout }
        return returnTarget(in: workspaces).map(EscapeAction.leave) ?? .none
    }

    static func page(of destination: Destination, workspaces: [UUID]) -> Int {
        switch destination {
        case .settings: return 0
        case .workspace(let id): return (workspaces.firstIndex(of: id) ?? 0) + 1
        }
    }

    static func destination(forPage page: Int, workspaces: [UUID]) -> Destination? {
        if page == 0 { return .settings }
        let index = page - 1
        return workspaces.indices.contains(index) ? .workspace(workspaces[index]) : nil
    }

    /// `direction` +1 is the next page (a swipe left), -1 the previous one.
    static func swipe(from destination: Destination, direction: Int, workspaces: [UUID]) -> Destination? {
        Self.destination(forPage: page(of: destination, workspaces: workspaces) + direction, workspaces: workspaces)
    }
}

// MARK: - Hover dwell

struct DwellToken: Hashable { let id: Int }

@MainActor
protocol DwellClock: AnyObject {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> DwellToken
    func cancel(_ token: DwellToken)
}

/// The run loop's clock.
@MainActor
final class MainQueueDwellClock: DwellClock {
    private var items: [DwellToken: DispatchWorkItem] = [:]
    private var nextId = 0

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> DwellToken {
        nextId += 1
        let token = DwellToken(id: nextId)
        let item = DispatchWorkItem { [weak self] in
            self?.items[token] = nil
            action()
        }
        items[token] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return token
    }

    func cancel(_ token: DwellToken) {
        items.removeValue(forKey: token)?.cancel()
    }
}

/// Resting on a tile previews its page color after a short dwell, so running the pointer
/// down the column doesn't strobe. Keyboard focus previews at once.
@MainActor
final class HoverDwell {
    static let defaultDelay: TimeInterval = 0.22

    var onPreview: ((UUID?) -> Void)?
    private(set) var previewed: UUID?
    private let delay: TimeInterval
    private let clock: DwellClock
    private var pending: (id: UUID, token: DwellToken)?

    init(delay: TimeInterval = HoverDwell.defaultDelay, clock: DwellClock) {
        self.delay = delay
        self.clock = clock
    }

    func pointerEntered(_ id: UUID) {
        cancelPending()
        guard previewed != id else { return }
        let token = clock.schedule(after: delay) { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.pending = nil
            self.setPreview(id)
        }
        pending = (id, token)
    }

    func pointerExited(_ id: UUID) {
        if pending?.id == id { cancelPending() }
        if previewed == id { setPreview(nil) }
    }

    func focusChanged(_ id: UUID?) {
        cancelPending()
        setPreview(id)
    }

    func reset() {
        cancelPending()
        previewed = nil
    }

    private func cancelPending() {
        if let pending { clock.cancel(pending.token) }
        pending = nil
    }

    private func setPreview(_ id: UUID?) {
        guard previewed != id else { return }
        previewed = id
        onPreview?(id)
    }
}

// MARK: - Flyout placement

/// The editor (258pt) and the app sheet (276pt) float beside the rail, never widening the
/// window. They open to the right and flip left when the screen runs out.
enum FlyoutPlacement {
    enum Side { case right, left }
    struct Vertical { var minY: CGFloat; var maxY: CGFloat; var arrowFromTop: CGFloat }

    static let gap: CGFloat = 8
    /// The arrow keeps this far from the flyout's rounded corners.
    static let arrowMargin: CGFloat = 16

    static func side(width: CGFloat, rail: NSRect, screen: NSRect) -> Side {
        let right = screen.maxX - rail.maxX
        let left = rail.minX - screen.minX
        let needed = width + gap
        if right >= needed { return .right }
        if left >= needed { return .left }
        return right >= left ? .right : .left
    }

    static func originX(side: Side, width: CGFloat, rail: NSRect) -> CGFloat {
        side == .right ? rail.maxX + gap : rail.minX - gap - width
    }

    /// AppKit coordinates (y up). The flyout's top sits `topInset` above the anchor's
    /// middle, then is clamped to the screen; the arrow keeps pointing at the anchor.
    static func vertical(height: CGFloat, anchorMidY: CGFloat, topInset: CGFloat, screen: NSRect) -> Vertical {
        var top = anchorMidY + topInset
        top = min(top, screen.maxY)
        top = max(top, screen.minY + height)
        let arrow = min(max(top - anchorMidY, arrowMargin), height - arrowMargin)
        return Vertical(minY: top - height, maxY: top, arrowFromTop: arrow)
    }
}

// MARK: - App sheet

enum AppWindowMode: Int { case floating, onTop, attached }

enum AppSheetSection: CaseIterable {
    case appearance, window, browser, shortcut, importing

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .window: return "Window"
        case .browser: return "Browser"
        case .shortcut: return "Shortcut"
        case .importing: return "Import"
        }
    }
}

/// Everything that isn't about one workspace, behind the quiet cell, most-changed first.
enum AppSheet {
    static let sections: [AppSheetSection] = [.appearance, .window, .browser, .shortcut, .importing]

    /// The quiet cell speaks up only when something needs you.
    static func showsBadge(windowMode: AppWindowMode, hasAccessibility: Bool) -> Bool {
        windowMode == .attached && !hasAccessibility
    }
}

// MARK: - Tile identity

/// What a workspace tile shows: its favicon mosaic, a letter, or a symbol.
enum WorkspaceTileIdentity: Equatable {
    case mosaic([Link]), letter(String), symbol(String)

    /// The eight symbols the editor offers, as SF Symbols.
    static let symbols = ["house", "hammer", "book", "flask", "paperplane", "star", "music.note", "cart"]

    static func resolve(_ workspaces: [Workspace]) -> [UUID: WorkspaceTileIdentity] {
        var result: [UUID: WorkspaceTileIdentity] = [:]
        var letterItems: [WorkspaceStripLayout.Item] = []
        for workspace in workspaces {
            switch workspace.icon {
            case .symbol(let name):
                result[workspace.id] = .symbol(name)
            case .favicons:
                let links = WorkspaceIconSites.pick(from: workspace.items)
                if links.isEmpty {
                    letterItems.append(.init(id: workspace.id, name: workspace.name))
                } else {
                    result[workspace.id] = .mosaic(links)
                }
            case .letter:
                letterItems.append(.init(id: workspace.id, name: workspace.name))
            }
        }
        // Letters only need to differ from the other letter tiles.
        WorkspaceStripLayout.assignMonograms(&letterItems)
        for item in letterItems { result[item.id] = .letter(item.monogram) }
        return result
    }
}
