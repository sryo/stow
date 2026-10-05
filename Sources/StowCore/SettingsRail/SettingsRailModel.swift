import AppKit

// The 52pt rail's geometry and the small rules behind it, kept free of views so they
// can be tested. Geometry is in the rail's flipped coordinates.

// MARK: - Layout

/// The gear heads the rail, the workspace chip (a 30pt tile over a "▾") sits under it,
/// and a thin rule separates them from the items.
enum RailLayout {
    static let railWidth: CGFloat = 52
    static let gearFrame = NSRect(x: 19, y: 13, width: 14, height: 14)
    static let chipTile: CGFloat = 30
    static let chipFrame = NSRect(x: 7, y: 35, width: 38, height: 44)
    static let separatorY: CGFloat = chipFrame.maxY + 6
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

/// Resting on a rail cell shows its tip after a short dwell, so running the pointer down
/// the column doesn't strobe. Keyboard focus shows it at once.
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
/// window. They open to the right and flip left when the screen runs out. Flyouts from a
/// Tabline item or a title-bar button hang `below` their anchor instead.
enum FlyoutPlacement {
    enum Side { case right, left }
    struct Vertical { var minY: CGFloat; var maxY: CGFloat; var arrowFromTop: CGFloat }
    struct Below { var minX: CGFloat; var maxY: CGFloat; var arrowFromLeft: CGFloat }
    struct Above { var minX: CGFloat; var minY: CGFloat; var arrowFromLeft: CGFloat }

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

    /// AppKit coordinates (y up). The card's top sits `gap` under the anchor, centred on
    /// it and clamped to the screen's sides; the arrow keeps pointing at the anchor.
    static func below(width: CGFloat, anchor: NSRect, screen: NSRect) -> Below {
        var x = anchor.midX - width / 2
        x = min(x, screen.maxX - gap - width)
        x = max(x, screen.minX + gap)
        let arrow = min(max(anchor.midX - x, arrowMargin), width - arrowMargin)
        return Below(minX: x, maxY: anchor.minY - gap, arrowFromLeft: arrow)
    }

    /// The mirror of `below`, for an anchor at the bottom of the screen (the Tabline on
    /// the bottom edge): the card's bottom sits `gap` over the anchor.
    static func above(width: CGFloat, anchor: NSRect, screen: NSRect) -> Above {
        let b = below(width: width, anchor: anchor, screen: screen)
        return Above(minX: b.minX, minY: anchor.maxY + gap, arrowFromLeft: b.arrowFromLeft)
    }
}

// MARK: - App sheet

/// The three "Where Stow lives" cards. Floating and On top are Stow's own window (On top
/// is Floating that stays above other apps); Attached is any edge of the browser.
enum AppWindowMode: Int, CaseIterable { case floating, onTop, attached }

enum AppSheetWindowRow: Equatable { case placement, openAtLogin }

enum AppSheetSection: CaseIterable {
    case window, keyboard, appearance

    var title: String {
        switch self {
        case .window: return WindowPlacementCopy.groupTitle
        case .keyboard: return "Keyboard"
        case .appearance: return "Appearance"
        }
    }
}

extension BrowserDock {
    /// The four edges: the sidebar's sides, then the Tabline's edges.
    static let edges: [BrowserDock] = [.left, .right, .top, .bottom]
}

/// Which card is chosen, and which edge the Attached card and the edge picker draw: the
/// dock while attached, and the edge Attached would go back to while not.
struct WindowPlacement: Equatable {
    var mode: AppWindowMode
    var edge: BrowserDock

    init(dock: BrowserDock, keepsOnTop: Bool, lastEdge: BrowserDock) {
        if dock != .none {
            mode = .attached
            edge = dock
        } else {
            mode = keepsOnTop ? .onTop : .floating
            edge = lastEdge == .none ? .left : lastEdge
        }
    }

    var dock: BrowserDock { mode == .attached ? edge : .none }
}

/// What sits under the cards: nothing, or the edge picker, alone or with the
/// Accessibility warning or the quiet "no browser in front" note.
enum WindowPlacementStatus: Equatable {
    case plain, edges, edgesNeedingAccessibility, edgesWithoutBrowser

    init(mode: AppWindowMode, hasAccessibility: Bool, browserInFront: Bool) {
        if mode != .attached {
            self = .plain
        } else if !hasAccessibility {
            self = .edgesNeedingAccessibility
        } else if !browserInFront {
            self = .edgesWithoutBrowser
        } else {
            self = .edges
        }
    }

    var showsEdges: Bool { self != .plain }
}

/// The words of "Where Stow lives".
enum WindowPlacementCopy {
    static let groupTitle = "Where Stow lives"
    static let ownWindow = "Its own window"
    static let onBrowser = "On your browser"
    static let previewTag = "CLICK TO USE"
    static let needsAccessibility = "Needs Accessibility permission."
    static let warningDetail = "Stow floats until you allow it."
    static let allow = "Allow…"
    static let noBrowser = "No browser window in front. Stow floats until one is."
    static let edgeGroup = "Edge of the browser window"

    static func name(_ mode: AppWindowMode) -> String {
        switch mode {
        case .floating: return "Floating"
        case .onTop: return "On top"
        case .attached: return "Attached"
        }
    }

    static func meaning(_ mode: AppWindowMode) -> String {
        switch mode {
        case .floating: return "A regular window you place anywhere. Other windows can cover it."
        case .onTop: return "A free window that stays above every other app."
        case .attached: return "Glued to your browser window. Moves and resizes with it."
        }
    }

    static func example(_ mode: AppWindowMode) -> String {
        switch mode {
        case .floating: return "Open Zoom over it and Stow waits behind."
        case .onTop: return "Stays above Zoom and Figma."
        case .attached: return "Drag Safari to another display; Stow comes along."
        }
    }

    static func edgeTitle(_ edge: BrowserDock) -> String {
        switch edge {
        case .left: return "Sidebar on the left"
        case .right: return "Sidebar on the right"
        case .top: return "Tabline on top"
        case .bottom: return "Tabline at the bottom"
        case .none: return "Not attached"
        }
    }

    static func edgeDetail(_ edge: BrowserDock) -> String {
        switch edge {
        case .left: return "Docks to the browser’s left side."
        case .right: return "Docks to the browser’s right side."
        case .top: return "Your tabs ride above the browser’s own."
        case .bottom: return "Your tabs ride under the browser window."
        case .none: return ""
        }
    }

    static func edgeHint(_ edge: BrowserDock) -> String {
        edge.isTabline ? "Tabline only rides the top or bottom edge." : "Click the top or bottom edge for the Tabline."
    }

    static func warningTitle(_ edge: BrowserDock) -> String {
        edge.isTabline ? "The Tabline needs Accessibility." : "Attached needs Accessibility."
    }

    /// The caption under the cards: the shown card's name, meaning and example, marked
    /// "Click to use" while hovering a card that isn't chosen (with the permission
    /// Attached needs, if it's missing).
    struct Description: Equatable {
        var mode: AppWindowMode
        var isPreview: Bool
        var accessibilityNote: String?
        var text: String { "\(WindowPlacementCopy.name(mode)). \(WindowPlacementCopy.meaning(mode))" }
        var example: String { WindowPlacementCopy.example(mode) }
    }

    static func description(shown: AppWindowMode, selected: AppWindowMode, hasAccessibility: Bool) -> Description {
        let preview = shown != selected
        let note = shown == .attached && !hasAccessibility && preview ? needsAccessibility : nil
        return Description(mode: shown, isPreview: preview, accessibilityNote: note)
    }
}

/// Everything that isn't about one workspace: behind the quiet cell in the rail, and
/// below Workspaces on the Settings page. Import and iCloud live in its footer.
enum AppSheet {
    static let sections: [AppSheetSection] = [.window, .keyboard, .appearance]

    /// The Where Stow lives group's rows. Keep on top is the On top card.
    static func windowRows(dock: BrowserDock) -> [AppSheetWindowRow] {
        [.placement, .openAtLogin]
    }

    struct SyncLine: Equatable {
        var text: String
        var isError: Bool
    }

    /// The footer's iCloud status. Sync has no switch: it's on whenever iCloud is.
    static func syncLine(availability: SyncAvailability, lastSync: Date?, signedOut: Bool, now: Date = Date()) -> SyncLine {
        switch availability {
        case .disabledNoProvisioningProfile:
            return SyncLine(text: "iCloud is off in this build", isError: true)
        case .notConfigured:
            return SyncLine(text: "iCloud is off for Stow", isError: true)
        case .active:
            if signedOut { return SyncLine(text: "iCloud is off for Stow", isError: true) }
            guard let lastSync else { return SyncLine(text: "Syncing with iCloud", isError: false) }
            let seconds = now.timeIntervalSince(lastSync)
            if seconds < 60 { return SyncLine(text: "Synced · just now", isError: false) }
            if seconds < 3600 { return SyncLine(text: "Synced · \(Int(seconds / 60)) min ago", isError: false) }
            if seconds < 86400 { return SyncLine(text: "Synced · \(Int(seconds / 3600)) h ago", isError: false) }
            return SyncLine(text: "Synced · \(Int(seconds / 86400)) d ago", isError: false)
        }
    }

    /// The permissions line: one entry per missing permission, each with a Fix button.
    static func permissionNeeds(dock: BrowserDock, hasAccessibility: Bool,
                                automationDenied browserName: String?) -> [PermissionNeed] {
        var needs: [PermissionNeed] = []
        if !hasAccessibility {
            if dock.isSidebar { needs.append(.accessibility(reason: "Attached needs Accessibility")) }
            if dock.isTabline { needs.append(.accessibility(reason: "The Tabline needs Accessibility")) }
        }
        if let browserName {
            needs.append(.automation(reason: "Switching to open tabs needs Automation for \(browserName)"))
        }
        return needs
    }

    /// The quiet cell speaks up only when something needs you.
    static func showsBadge(needs: [PermissionNeed]) -> Bool {
        !needs.isEmpty
    }
}

enum PermissionNeed: Equatable {
    case accessibility(reason: String)
    case automation(reason: String)

    var reason: String {
        switch self {
        case .accessibility(let reason), .automation(let reason): return reason
        }
    }
}

// MARK: - New workspace

/// A new workspace takes the next palette color nobody uses, and a distinct allocated
/// hue once all eight are taken.
enum NewWorkspaceColor {
    static func pick(existing: [WorkspaceColorId]) -> WorkspaceColorId {
        WorkspaceColorId.allCases.first { !existing.contains($0) } ?? WorkspaceColorAllocator.next(existing: existing)
    }
}

// MARK: - Motion

/// Whether the rail's animations run. Reduce Motion swaps instantly.
enum RailMotion {
    static func animates(windowVisible: Bool, swiping: Bool, reduceMotion: Bool) -> Bool {
        windowVisible && !swiping && !reduceMotion
    }

    @MainActor
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
