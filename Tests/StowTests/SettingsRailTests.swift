import XCTest
import AppKit
@testable import StowCore

// MARK: - Tile column layout

final class SettingsRailLayoutTests: XCTestCase {
    typealias L = SettingsRailLayout

    func testTilesStackAtTheConceptPitch() {
        // 36pt tile, 12pt caption under it, 59pt from one tile to the next.
        XCTAssertEqual(L.tileFrame(at: 0), NSRect(x: 8, y: 0, width: 36, height: 36))
        XCTAssertEqual(L.tileFrame(at: 2), NSRect(x: 8, y: 118, width: 36, height: 36))
        XCTAssertEqual(L.captionFrame(at: 2), NSRect(x: 2, y: 156, width: 48, height: 12))
        XCTAssertEqual(L.rowFrame(at: 3), NSRect(x: 0, y: 177, width: 52, height: 51))
    }

    func testCameFromDotSitsInTheLeftMarginOfItsTile() {
        XCTAssertEqual(L.cameFromDotFrame(at: 2), NSRect(x: 2, y: 134, width: 4, height: 4))
    }

    func testDashedTileFollowsTheLastWorkspace() {
        XCTAssertEqual(L.addTileFrame(count: 4), NSRect(x: 8, y: 236, width: 36, height: 36))
        XCTAssertEqual(L.addTileFrame(count: 0).minY, 0)
        XCTAssertEqual(L.contentHeight(count: 4), 236 + 36)
    }

    func testListLeavesRoomForGearAndQuietCell() {
        XCTAssertEqual(L.listTop, 46)
        XCTAssertEqual(L.listHeight(railHeight: 640), 640 - 46 - 52)
        XCTAssertEqual(L.quietCellFrame(railHeight: 640), NSRect(x: 11, y: 600, width: 30, height: 30))
        XCTAssertEqual(L.gearFrame, NSRect(x: 19, y: 13, width: 14, height: 14))
    }

    func testNineFitIn640AndOnlyTheDashedTileScrolls() {
        XCTAssertFalse(L.scrolls(count: 4, railHeight: 640))
        XCTAssertFalse(L.scrolls(count: 8, railHeight: 640))
        XCTAssertTrue(L.scrolls(count: 9, railHeight: 640), "past nine the dashed tile scrolls into view")
        XCTAssertEqual(L.fullyVisibleTileCount(railHeight: 640), 9)
        XCTAssertTrue(L.scrolls(count: 4, railHeight: 300))
    }

    func testCaptionsKeepShortNamesAndCutLongOnesWithAnEllipsis() {
        XCTAssertEqual(L.caption("Research"), "Research")
        XCTAssertEqual(L.caption("Shopping"), "Shopping")
        let lisbon = L.caption("Lisbon trip")
        XCTAssertTrue(lisbon.hasPrefix("Lisbon"), lisbon)
        XCTAssertTrue(lisbon.hasSuffix("…"), lisbon)
        let side = L.caption("Side project")
        XCTAssertTrue(side.hasPrefix("Side"), side)
        XCTAssertTrue(side.hasSuffix("…"), side)
        for name in ["Lisbon trip", "Side project", "An extremely long workspace name"] {
            XCTAssertLessThanOrEqual(L.captionWidth(L.caption(name)), L.captionFrame(at: 0).width, name)
        }
        XCTAssertEqual(L.caption("  "), "")
    }

    func testDotsOnTheWorkspacePageSitUnderTheGear() {
        // Gear at 13, then one 12pt dot every 18pt (the dot "grows" from here into its tile).
        XCTAssertEqual(L.dotCenterY(at: 0), 37)
        XCTAssertEqual(L.dotCenterY(at: 2), 73)
        XCTAssertEqual(L.dotsSeparatorY(count: 4), 13 + 18 * 5 + 4)
    }
}

// MARK: - Drag to reorder

final class TileReorderTests: XCTestCase {
    func testDragStartsAfterFourPoints() {
        XCTAssertFalse(TileReorder.hasStarted(dy: 3.9))
        XCTAssertTrue(TileReorder.hasStarted(dy: -4))
    }

    func testTargetIndexRoundsToTheNearestSlot() {
        XCTAssertEqual(TileReorder.targetIndex(tileTop: 50, count: 4), 1, "the concept's Reading-up frame")
        XCTAssertEqual(TileReorder.targetIndex(tileTop: 29, count: 4), 0)
        XCTAssertEqual(TileReorder.targetIndex(tileTop: 30, count: 4), 1)
        XCTAssertEqual(TileReorder.targetIndex(tileTop: 118, count: 4), 2)
    }

    func testTargetIndexClampsAtBothEnds() {
        XCTAssertEqual(TileReorder.targetIndex(tileTop: -200, count: 4), 0)
        XCTAssertEqual(TileReorder.targetIndex(tileTop: 5000, count: 4), 3, "dragging past the end lands last")
        XCTAssertEqual(TileReorder.targetIndex(tileTop: 40, count: 1), 0)
        XCTAssertEqual(TileReorder.clampedTileTop(5000, count: 4), 3 * 59 + 10)
        XCTAssertEqual(TileReorder.clampedTileTop(-200, count: 4), -10)
    }

    func testOrderPreviewMovesOnlyTheDraggedTile() {
        XCTAssertEqual(TileReorder.order(["a", "b", "c", "d"], moving: "d", to: 1), ["a", "d", "b", "c"])
        XCTAssertEqual(TileReorder.order(["a", "b", "c", "d"], moving: "a", to: 3), ["b", "c", "d", "a"])
        XCTAssertEqual(TileReorder.order(["a", "b", "c", "d"], moving: "b", to: 1), ["a", "b", "c", "d"])
    }

    func testNotMovingIsNoMove() {
        XCTAssertNil(TileReorder.move(from: 2, to: 2))
        XCTAssertEqual(TileReorder.move(from: 0, to: 3), 3)
    }

    func testDropBarSitsJustAboveTheSlot() {
        XCTAssertEqual(TileReorder.dropIndicatorY(to: 1), 59 - 5)
        XCTAssertEqual(TileReorder.dropIndicatorY(to: 0), -5)
    }
}

// MARK: - Navigation

final class SettingsRailNavigationTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()
    var all: [UUID] { [a, b, c] }

    func testEnteringRemembersWhereYouCameFrom() {
        var nav = SettingsRailNavigation()
        nav.didEnterSettings(from: b)
        XCTAssertEqual(nav.cameFrom, b)
        XCTAssertEqual(nav.cameFromIndex(in: all), 1)
    }

    func testGearTogglesBetweenSettingsAndWhereYouCameFrom() {
        var nav = SettingsRailNavigation()
        XCTAssertEqual(nav.gearDestination(isOnSettings: false, workspaces: all), .settings)
        nav.didEnterSettings(from: c)
        XCTAssertEqual(nav.gearDestination(isOnSettings: true, workspaces: all), .workspace(c))
    }

    func testReturnFallsBackToTheFirstWorkspaceWhenCameFromIsGone() {
        var nav = SettingsRailNavigation()
        nav.didEnterSettings(from: b)
        XCTAssertEqual(nav.gearDestination(isOnSettings: true, workspaces: [a, c]), .workspace(a))
        XCTAssertNil(nav.cameFromIndex(in: [a, c]))
        nav.didEnterSettings(from: nil)
        XCTAssertEqual(nav.gearDestination(isOnSettings: true, workspaces: all), .workspace(a))
    }

    func testCameFromFollowsTheWorkspaceThroughAReorder() {
        var nav = SettingsRailNavigation()
        nav.didEnterSettings(from: a)
        XCTAssertEqual(nav.cameFromIndex(in: [b, c, a]), 2)
    }

    func testEscClosesAFlyoutFirstThenLeaves() {
        var nav = SettingsRailNavigation()
        nav.didEnterSettings(from: b)
        XCTAssertEqual(nav.escapeAction(isOnSettings: true, flyoutOpen: true, workspaces: all), .closeFlyout)
        XCTAssertEqual(nav.escapeAction(isOnSettings: true, flyoutOpen: false, workspaces: all), .leave(b))
        XCTAssertEqual(nav.escapeAction(isOnSettings: false, flyoutOpen: false, workspaces: all), .none)
    }

    func testSettingsIsPageZeroAndSwipesWalkThePages() {
        typealias N = SettingsRailNavigation
        XCTAssertEqual(N.page(of: .settings, workspaces: all), 0)
        XCTAssertEqual(N.page(of: .workspace(b), workspaces: all), 2)
        XCTAssertEqual(N.destination(forPage: 0, workspaces: all), .settings)
        XCTAssertEqual(N.destination(forPage: 1, workspaces: all), .workspace(a))
        XCTAssertNil(N.destination(forPage: 4, workspaces: all), "the add-new page isn't a destination")
        // Swiping left (next page) from Settings opens workspace 1; swiping right past it returns.
        XCTAssertEqual(N.swipe(from: .settings, direction: 1, workspaces: all), .workspace(a))
        XCTAssertEqual(N.swipe(from: .workspace(a), direction: -1, workspaces: all), .settings)
        XCTAssertNil(N.swipe(from: .settings, direction: -1, workspaces: all))
        XCTAssertEqual(N.swipe(from: .workspace(b), direction: 1, workspaces: all), .workspace(c))
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
}

// MARK: - App sheet

final class AppSheetTests: XCTestCase {
    func testSectionsFollowTheConceptOrder() {
        XCTAssertEqual(AppSheet.sections, [.appearance, .window, .browser, .shortcut, .importing])
        XCTAssertEqual(AppSheet.sections.map(\.title), ["Appearance", "Window", "Browser", "Shortcut", "Import"])
    }

    func testBadgeOnlyWhenAttachedIsMissingAccessibility() {
        XCTAssertTrue(AppSheet.showsBadge(windowMode: .attached, hasAccessibility: false))
        XCTAssertFalse(AppSheet.showsBadge(windowMode: .attached, hasAccessibility: true))
        XCTAssertFalse(AppSheet.showsBadge(windowMode: .floating, hasAccessibility: false))
        XCTAssertFalse(AppSheet.showsBadge(windowMode: .onTop, hasAccessibility: false))
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
