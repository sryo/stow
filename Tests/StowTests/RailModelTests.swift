import XCTest
import AppKit
@testable import StowCore

// MARK: - Rail layout

final class RailLayoutTests: XCTestCase {
    typealias L = RailLayout

    func testDotsSitUnderTheGearAndThePlusDotEndsThem() {
        // Gear at 13, then one 12pt dot every 18pt; the "+" dot takes the next slot.
        XCTAssertEqual(L.gearFrame, NSRect(x: 19, y: 13, width: 14, height: 14))
        XCTAssertEqual(L.dotCenterY(at: 0), 37)
        XCTAssertEqual(L.dotCenterY(at: 2), 73)
        XCTAssertEqual(L.dotsSeparatorY(count: 4), 13 + 18 * 6 + 4, "the rule sits under the \"+\" dot")
    }

    func testOneSwipeInTheRailMovesOnePage() {
        // The rail's content is ~36pt wide; paging by that would fly past several pages.
        XCTAssertEqual(RailSwipe.pageWidth(contentWidth: 36, isRail: true), 160)
        XCTAssertEqual(RailSwipe.pageWidth(contentWidth: 300, isRail: false), 300)
        XCTAssertEqual(RailSwipe.pageWidth(contentWidth: 90, isRail: false), 90)
    }
}

// MARK: - Hover dwell

@MainActor
final class ManualClock: DwellClock {
    private(set) var now: TimeInterval = 0
    private var pending: [(id: Int, at: TimeInterval, action: () -> Void)] = []
    private var nextId = 0

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> DwellToken {
        nextId += 1
        pending.append((nextId, now + delay, action))
        return DwellToken(id: nextId)
    }

    func cancel(_ token: DwellToken) {
        pending.removeAll { $0.id == token.id }
    }

    func advance(by dt: TimeInterval) {
        now += dt
        let due = pending.filter { $0.at <= now + 1e-9 }
        pending.removeAll { $0.at <= now + 1e-9 }
        due.forEach { $0.action() }
    }
}

@MainActor
final class HoverDwellTests: XCTestCase {
    let a = UUID(), b = UUID()

    private func make() -> (HoverDwell, ManualClock, () -> [UUID?]) {
        let clock = ManualClock()
        let dwell = HoverDwell(clock: clock)
        var log: [UUID?] = []
        dwell.onPreview = { log.append($0) }
        return (dwell, clock, { log })
    }

    func testDefaultDelayIs220ms() {
        XCTAssertEqual(HoverDwell.defaultDelay, 0.22, accuracy: 1e-9)
    }

    func testPreviewArrivesAfterTheDwell() {
        let (dwell, clock, log) = make()
        dwell.pointerEntered(a)
        clock.advance(by: 0.219)
        XCTAssertNil(dwell.previewed)
        XCTAssertTrue(log().isEmpty)
        clock.advance(by: 0.002)
        XCTAssertEqual(dwell.previewed, a)
        XCTAssertEqual(log(), [a])
    }

    func testRunningThePointerDownTheColumnNeverStrobes() {
        let (dwell, clock, log) = make()
        for id in [a, b, a, b] {
            dwell.pointerEntered(id)
            clock.advance(by: 0.05)
            dwell.pointerExited(id)
        }
        clock.advance(by: 1)
        XCTAssertTrue(log().isEmpty)
    }

    func testMovingToAnotherTileRestartsTheDwell() {
        let (dwell, clock, _) = make()
        dwell.pointerEntered(a)
        clock.advance(by: 0.1)
        dwell.pointerExited(a)
        dwell.pointerEntered(b)
        clock.advance(by: 0.15)
        XCTAssertNil(dwell.previewed)
        clock.advance(by: 0.08)
        XCTAssertEqual(dwell.previewed, b)
    }

    func testLeavingClearsThePreviewAtOnce() {
        let (dwell, clock, log) = make()
        dwell.pointerEntered(a)
        clock.advance(by: 0.3)
        dwell.pointerExited(a)
        XCTAssertNil(dwell.previewed)
        XCTAssertEqual(log(), [a, nil])
    }

    func testKeyboardFocusPreviewsWithoutWaiting() {
        let (dwell, _, log) = make()
        dwell.focusChanged(b)
        XCTAssertEqual(dwell.previewed, b)
        dwell.focusChanged(nil)
        XCTAssertNil(dwell.previewed)
        XCTAssertEqual(log(), [b, nil])
    }

    func testResetCancelsAPendingDwell() {
        let (dwell, clock, log) = make()
        dwell.pointerEntered(a)
        dwell.reset()
        clock.advance(by: 1)
        XCTAssertTrue(log().isEmpty)
    }
}

// MARK: - Flyout placement

final class FlyoutPlacementTests: XCTestCase {
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    func testOpensToTheRightWhenThereIsRoom() {
        let rail = NSRect(x: 200, y: 100, width: 52, height: 640)
        XCTAssertEqual(FlyoutPlacement.side(width: 258, rail: rail, screen: screen), .right)
        XCTAssertEqual(FlyoutPlacement.originX(side: .right, width: 258, rail: rail), 260)
    }

    func testFlipsLeftAtTheRightScreenEdge() {
        let rail = NSRect(x: 1440 - 52, y: 100, width: 52, height: 640)
        XCTAssertEqual(FlyoutPlacement.side(width: 258, rail: rail, screen: screen), .left)
        XCTAssertEqual(FlyoutPlacement.originX(side: .left, width: 258, rail: rail), 1440 - 52 - 8 - 258)
        // The sheet is wider and flips at a slightly larger margin.
        let nearEdge = NSRect(x: 1440 - 52 - 270, y: 100, width: 52, height: 640)
        XCTAssertEqual(FlyoutPlacement.side(width: 258, rail: nearEdge, screen: screen), .right)
        XCTAssertEqual(FlyoutPlacement.side(width: 276, rail: nearEdge, screen: screen), .left)
    }

    func testPicksTheRoomierSideWhenNeitherFits() {
        let small = NSRect(x: 0, y: 0, width: 400, height: 900)
        XCTAssertEqual(FlyoutPlacement.side(width: 258, rail: NSRect(x: 100, y: 0, width: 52, height: 600), screen: small), .right)
        XCTAssertEqual(FlyoutPlacement.side(width: 258, rail: NSRect(x: 250, y: 0, width: 52, height: 600), screen: small), .left)
    }

    func testVerticalFrameStaysOnScreenAndTheArrowKeepsPointing() {
        // AppKit coordinates: y grows upward. Anchor near the top of the screen.
        let placed = FlyoutPlacement.vertical(height: 372, anchorMidY: 880, topInset: 23, screen: screen)
        XCTAssertEqual(placed.maxY, 900, "clamped to the screen top")
        XCTAssertEqual(placed.minY, 900 - 372)
        XCTAssertEqual(placed.arrowFromTop, 20, accuracy: 0.01)
        let mid = FlyoutPlacement.vertical(height: 372, anchorMidY: 500, topInset: 23, screen: screen)
        XCTAssertEqual(mid.maxY, 523)
        XCTAssertEqual(mid.arrowFromTop, 23, accuracy: 0.01)
        let low = FlyoutPlacement.vertical(height: 372, anchorMidY: 30, topInset: 23, screen: screen)
        XCTAssertEqual(low.minY, 0)
        XCTAssertLessThanOrEqual(low.arrowFromTop, 372 - 16)
    }

    func testBelowCentresUnderTheAnchorAndKeepsTheArrowOnIt() {
        let anchor = NSRect(x: 600, y: 700, width: 80, height: 24)
        let placed = FlyoutPlacement.below(width: 240, anchor: anchor, screen: screen)
        XCTAssertEqual(placed.minX, 640 - 120)
        XCTAssertEqual(placed.maxY, 700 - FlyoutPlacement.gap)
        XCTAssertEqual(placed.arrowFromLeft, 120, accuracy: 0.01)
    }

    func testBelowStaysOnScreenAtTheEdge() {
        let anchor = NSRect(x: 1420, y: 700, width: 16, height: 16)
        let placed = FlyoutPlacement.below(width: 240, anchor: anchor, screen: screen)
        XCTAssertEqual(placed.minX + 240, 1440 - FlyoutPlacement.gap)
        XCTAssertLessThanOrEqual(placed.arrowFromLeft, 240 - FlyoutPlacement.arrowMargin)
    }
}

// MARK: - App sheet

final class AppSheetTests: XCTestCase {
    func testGroupsFollowThePlan() {
        // Where Stow lives, Keyboard, Appearance; Import moved to the footer, Theme and Browser are gone.
        XCTAssertEqual(AppSheet.sections, [.window, .keyboard, .appearance])
        XCTAssertEqual(AppSheet.sections.map(\.title), ["Where Stow lives", "Keyboard", "Appearance"])
    }

    func testWindowRowsAreTheCardsAndOpenAtLogin() {
        // No Keep on top switch (it's the On top card) and no left/right question for the Tabline.
        for dock in BrowserDock.allCases {
            XCTAssertEqual(AppSheet.windowRows(dock: dock), [.placement, .openAtLogin])
        }
    }

    func testICloudLine() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(AppSheet.syncLine(availability: .active, lastSync: now.addingTimeInterval(-20), signedOut: false, now: now),
                       .init(text: "Synced · just now", isError: false))
        XCTAssertEqual(AppSheet.syncLine(availability: .active, lastSync: now.addingTimeInterval(-125), signedOut: false, now: now),
                       .init(text: "Synced · 2 min ago", isError: false))
        XCTAssertEqual(AppSheet.syncLine(availability: .active, lastSync: nil, signedOut: false, now: now),
                       .init(text: "Syncing with iCloud", isError: false))
        XCTAssertEqual(AppSheet.syncLine(availability: .active, lastSync: now, signedOut: true, now: now),
                       .init(text: "iCloud is off for Stow", isError: true))
        XCTAssertEqual(AppSheet.syncLine(availability: .disabledNoProvisioningProfile, lastSync: nil, signedOut: false, now: now),
                       .init(text: "iCloud is off in this build", isError: true))
    }
}

// MARK: - Tile identity

final class WorkspaceTileIdentityTests: XCTestCase {
    private func link(_ host: String, favicon: Bool = true) -> Node {
        .link(Link(id: UUID(), title: host, url: "https://\(host)/", faviconPath: favicon ? "/tmp/\(host).png" : nil))
    }

    func testFaviconsShowAMosaicOfUpToFourSites() {
        let ws = Workspace(id: UUID(), name: "Research", colorId: .ocean,
                           items: ["linear.app", "figma.com", "notion.so", "arxiv.org", "vercel.com"].map { link($0) })
        guard case .mosaic(let links) = WorkspaceTileIdentity.resolve([ws])[ws.id] else { return XCTFail() }
        XCTAssertEqual(links.count, 4)
    }

    func testFaviconsWithoutAnyFaviconFallBackToALetter() {
        let ws = Workspace(id: UUID(), name: "reading", colorId: .graphite, items: [link("x.org", favicon: false)])
        XCTAssertEqual(WorkspaceTileIdentity.resolve([ws])[ws.id], .letter("R"))
    }

    func testLettersAreMonogramsAmongLetterTiles() {
        let research = Workspace(id: UUID(), name: "Research", colorId: .ocean, items: [link("linear.app")])
        let reading = Workspace(id: UUID(), name: "Reading", colorId: .graphite, items: [], icon: .letter)
        XCTAssertEqual(WorkspaceTileIdentity.resolve([research, reading])[reading.id], .letter("R"),
                       "a mosaic tile doesn't take the letter")
        let recipes = Workspace(id: UUID(), name: "Recipes", colorId: .ember, items: [], icon: .letter)
        let both = WorkspaceTileIdentity.resolve([reading, recipes])
        XCTAssertNotEqual(both[reading.id], both[recipes.id])
    }

    func testSymbolShowsItsGlyph() {
        let ws = Workspace(id: UUID(), name: "Personal", colorId: .ruby, items: [], icon: .symbol("house"))
        XCTAssertEqual(WorkspaceTileIdentity.resolve([ws])[ws.id], .symbol("house"))
        XCTAssertEqual(WorkspaceTileIdentity.symbols.count, 8)
        XCTAssertEqual(WorkspaceTileIdentity.symbols.first, "house")
    }
}

// MARK: - New workspace color

final class NewWorkspaceColorTests: XCTestCase {
    func testTakesTheFirstPaletteColorNoWorkspaceUses() {
        XCTAssertEqual(NewWorkspaceColor.pick(existing: [.ember, .ruby]), .coral)
        XCTAssertEqual(NewWorkspaceColor.pick(existing: []), .ember)
        XCTAssertEqual(NewWorkspaceColor.pick(existing: [.ember, .custom("#123456"), .ruby, .coral]), .tangerine)
    }

    func testFallsBackToADistinctHueOnceAllEightAreTaken() {
        let color = NewWorkspaceColor.pick(existing: WorkspaceColorId.allCases)
        guard case .custom = color else { return XCTFail("expected an allocated custom color, got \(color)") }
    }
}

// MARK: - One page per swipe

final class SwipeStepTests: XCTestCase {
    func testARailSwipeMovesAtMostOnePage() {
        XCTAssertEqual(ScrollWheelPageController.clampTarget(2, start: 0, maxStep: 1), 1)
        XCTAssertEqual(ScrollWheelPageController.clampTarget(0, start: 3, maxStep: 1), 2)
        XCTAssertEqual(ScrollWheelPageController.clampTarget(1, start: 1, maxStep: 1), 1)
    }

    func testWithoutACapTheTargetStands() {
        XCTAssertEqual(ScrollWheelPageController.clampTarget(4, start: 0, maxStep: nil), 4)
    }
}

// MARK: - Settings page width

@MainActor
final class SettingsPageWidthTests: XCTestCase {
    func testContentIsCappedAndCentredOnAWideWindow() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("stow-page-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let model = AppModel(store: DataStore(baseDirectory: tempDir))
        let page = SettingsContentViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = page
        page.appModel = model
        window.setContentSize(NSSize(width: 820, height: 640))
        window.layoutIfNeeded()
        page.view.layoutSubtreeIfNeeded()
        let sheet = page.sheet.frame
        XCTAssertLessThanOrEqual(sheet.width, SettingsContentViewController.maxContentWidth)
        let pageWidth = page.sheet.superview!.bounds.width
        XCTAssertEqual(sheet.midX, pageWidth / 2, accuracy: 1, "the column is centred")
        XCTAssertEqual(SettingsContentViewController.contentColumn(width: 300), 0...300, "narrow pages use the full width")
    }
}

// MARK: - Shortcuts and timers (review wave 2B)

@MainActor
final class RailFollowThroughTests: XCTestCase {
    private var tempDir: URL!
    private var model: AppModel!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("stow-rail2b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
    }

    override func tearDown() async throws {
        model = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWorkspaceShortcutLabelsReadTheWindowMenu() {
        XCTAssertEqual(WorkspaceShortcut.label(position: 1), "⌘1")
        XCTAssertEqual(WorkspaceShortcut.label(position: 9), "⌘9")
        XCTAssertNil(WorkspaceShortcut.label(position: 10), "past nine there's no shortcut")
    }

    func testTheFooterTimerStopsWhenItsSheetHides() {
        let footer = AppSheetFooterView(showsVersion: false)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 276, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = footer
        panel.orderFront(nil)
        footer.updateTimer()
        XCTAssertTrue(footer.isTicking, "precondition: the footer counts while shown")
        panel.orderOut(nil)
        footer.updateTimer()
        XCTAssertFalse(footer.isTicking, "X5: the 30s timer keeps running after the sheet is ordered out")
        footer.isHidden = true
        panel.orderFront(nil)
        footer.updateTimer()
        XCTAssertFalse(footer.isTicking, "a hidden footer doesn't count")
        panel.close()
    }
}

// MARK: - Rail tips and hooks

@MainActor
final class RailTipAndHookTests: XCTestCase {
    private func link(_ title: String) -> Link {
        Link(id: UUID(), title: title, url: "https://\(title.lowercased()).com", faviconPath: nil)
    }

    private func rail(_ items: [Node], dots: [RailView.WorkspaceDot]) -> RailView {
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 52, height: 620))
        view.configure(workspaces: dots, selectedId: dots.first?.id, colorId: .defaultColor(), items: items)
        return view
    }

    private func subviews<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        view.subviews.flatMap { ([$0 as? T].compactMap { $0 }) + subviews(of: $0, type) }
    }

    func testRailCellsUseTheRailTipNotASystemTooltip() {
        let github = link("GitHub")
        let view = rail([.link(github)], dots: [.init(id: UUID(), name: "Alpha", color: .systemBlue)])
        let cell = subviews(of: view, RailCell.self).first
        XCTAssertNil(cell?.toolTip, "C7: the cell sets a system toolTip")
        XCTAssertEqual(cell?.tip, RailTipController.Tip(title: "GitHub", detail: "github.com"))
        XCTAssertEqual(cell?.accessibilityLabel(), "GitHub, link, github.com", "the VoiceOver label stays")
    }

    func testCellViewFindsTheCellForANode() {
        let github = link("GitHub")
        let view = rail([.link(github)], dots: [.init(id: UUID(), name: "Alpha", color: .systemBlue)])
        XCTAssertTrue(view.cellView(for: github.id) is RailCell)
        XCTAssertNil(view.cellView(for: UUID()))
    }

    func testADotRightClickAsksForTheEditorOnItsWorkspace() {
        let alpha = RailView.WorkspaceDot(id: UUID(), name: "Alpha", color: .systemBlue)
        let view = rail([], dots: [alpha])
        var edited: UUID?
        let dot = subviews(of: view, NSButton.self).first { $0.toolTip?.hasPrefix("Alpha") == true }
        XCTAssertEqual(dot?.toolTip, "Alpha · ⌘1", "the dot reports its tip text")
        view.onWorkspaceContextMenu = { id, _ in edited = id }
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        dot?.rightMouseDown(with: click)
        XCTAssertEqual(edited, alpha.id)
    }

    func testTheTipControllerShowsTheSourceTipAfterTheDwellAndHides() {
        let clock = ManualClock()
        let tips = RailTipController(clock: clock)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 52, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 38, height: 38))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let id = UUID()
        tips.hover(id, view: anchor, tip: .init(title: "GitHub", detail: "github.com"), inside: true)
        XCTAssertNil(tips.shown, "nothing before the dwell")
        clock.advance(by: 1)
        XCTAssertEqual(tips.shown?.title, "GitHub")
        XCTAssertTrue(tips.isVisible)
        tips.hover(id, view: anchor, tip: .init(title: "GitHub", detail: "github.com"), inside: false)
        XCTAssertNil(tips.shown, "leaving hides at once")
        tips.hover(id, view: anchor, tip: .init(title: "GitHub", detail: "github.com"), inside: true)
        clock.advance(by: 1)
        tips.hide()
        XCTAssertNil(tips.shown)
        XCTAssertFalse(tips.isVisible)
        window.close()
    }
}
