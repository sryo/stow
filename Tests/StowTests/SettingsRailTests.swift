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

    func testOneSwipeInTheRailMovesOnePage() {
        // The rail's content is ~36pt wide; paging by that would fly past several pages.
        XCTAssertEqual(SettingsRailNavigation.swipePageWidth(contentWidth: 36, isRail: true), 160)
        XCTAssertEqual(SettingsRailNavigation.swipePageWidth(contentWidth: 300, isRail: false), 300)
        XCTAssertEqual(SettingsRailNavigation.swipePageWidth(contentWidth: 90, isRail: false), 90)
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
        // Window, Keyboard, Appearance; Import moved to the footer, Theme and Browser are gone.
        XCTAssertEqual(AppSheet.sections, [.window, .keyboard, .appearance])
        XCTAssertEqual(AppSheet.sections.map(\.title), ["Window", "Keyboard", "Appearance"])
    }

    func testDockCaptionSaysWhatEachEdgeDoes() {
        XCTAssertEqual(AppSheet.dockCaption(.none), "Not attached · pick an edge")
        XCTAssertEqual(AppSheet.dockCaption(.left), "Sidebar on the left of your browser")
        XCTAssertEqual(AppSheet.dockCaption(.right), "Sidebar on the right of your browser")
        XCTAssertEqual(AppSheet.dockCaption(.top), "Tabs ride above your browser · ⌥⌘L")
        XCTAssertEqual(AppSheet.dockCaption(.bottom), "Tabs ride below your browser · ⌥⌘L")
    }

    func testWindowRowsFollowTheDock() {
        // No Browser side row any more, and no left/right question for the Tabline.
        XCTAssertEqual(AppSheet.windowRows(dock: .none), [.dock, .keepOnTop, .openAtLogin])
        XCTAssertEqual(AppSheet.windowRows(dock: .top), [.dock, .keepOnTop, .openAtLogin])
        XCTAssertEqual(AppSheet.windowRows(dock: .bottom), [.dock, .keepOnTop, .openAtLogin])
        XCTAssertEqual(AppSheet.windowRows(dock: .left), [.dock, .openAtLogin], "On top doesn't apply while attached")
        XCTAssertEqual(AppSheet.windowRows(dock: .right), [.dock, .openAtLogin])
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
        XCTAssertEqual(SettingsRailNewWorkspace.color(existing: [.ember, .ruby]), .coral)
        XCTAssertEqual(SettingsRailNewWorkspace.color(existing: []), .ember)
        XCTAssertEqual(SettingsRailNewWorkspace.color(existing: [.ember, .custom("#123456"), .ruby, .coral]), .tangerine)
    }

    func testFallsBackToADistinctHueOnceAllEightAreTaken() {
        let color = SettingsRailNewWorkspace.color(existing: WorkspaceColorId.allCases)
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

// MARK: - Settings rail through FlyoutController

@MainActor
final class SettingsRailFlyoutTests: XCTestCase {
    private var tempDir: URL!
    private var model: AppModel!
    private var controller: SettingsRailController!
    private var window: NSWindow!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("stow-rail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
        controller = SettingsRailController(model: model)
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 52, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 52, height: 640)
        controller.reload()
    }

    override func tearDown() async throws {
        controller.willLeave()
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        NSColorPanel.shared.orderOut(nil)
        window.close()
        controller = nil
        model = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testTheEditorAndTheSheetOpenThroughTheFlyoutController() {
        let id = model.currentWorkspace.id
        controller.view.onTileClick?(id)
        XCTAssertEqual(controller.flyouts.openIds, [SettingsRailController.FlyoutId.editor])
        controller.view.onQuiet?()
        XCTAssertEqual(controller.flyouts.openIds, [SettingsRailController.FlyoutId.sheet], "the sheet replaces the editor")
        XCTAssertNil(controller.editingId)
        controller.closeFlyouts()
        XCTAssertFalse(controller.flyouts.isOpen)
    }

    func testAllShortcutsIsPushedBesideTheSheetAndEscClosesOnlyIt() {
        controller.view.onQuiet?()
        controller.showAllShortcuts(from: NSRect(x: 300, y: 300, width: 80, height: 14))
        XCTAssertEqual(controller.flyouts.openIds, [SettingsRailController.FlyoutId.sheet, SettingsRailController.FlyoutId.allShortcuts])
        let panels = controller.flyouts.panels
        XCTAssertFalse(FlyoutDismissPolicy.clickCloses(window: panels[1], stack: panels, host: window),
                       "a click inside All shortcuts keeps the sheet open")
        XCTAssertTrue(controller.handleEscape())
        XCTAssertEqual(controller.flyouts.openIds, [SettingsRailController.FlyoutId.sheet], "one Esc closes only All shortcuts")
        XCTAssertTrue(controller.handleEscape())
        XCTAssertFalse(controller.flyouts.isOpen)
    }

    func testCustomColorPreviewsWhileDraggingAndCommitsOnceOnClose() {
        let id = model.currentWorkspace.id
        model.updateWorkspaceColor(id: id, colorId: .ocean)
        var previewed: [WorkspaceColorId?] = []
        controller.onPreviewColor = { previewed.append($0) }
        controller.view.onTileClick?(id)
        controller.chooseCustomColor()
        NSColorPanel.shared.color = .systemRed
        controller.customColorChanged(NSColorPanel.shared)
        XCTAssertEqual(model.workspaces.first { $0.id == id }?.colorId, .ocean, "dragging doesn't write the library")
        guard case .custom? = previewed.last ?? nil else { return XCTFail("the drag previews through onPreviewColor") }
        controller.view.onTileClick?(id)
        guard case .custom? = model.workspaces.first(where: { $0.id == id })?.colorId else {
            return XCTFail("closing the editor commits the custom color")
        }
        let committed = model.workspaces.first { $0.id == id }?.colorId
        NSColorPanel.shared.color = .systemBlue
        controller.customColorChanged(NSColorPanel.shared)
        XCTAssertEqual(model.workspaces.first { $0.id == id }?.colorId, committed, "the closed editor lets go of the panel")
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

// MARK: - Rail identity, tips and timers (review wave 2B)

@MainActor
final class SettingsRailFollowThroughTests: XCTestCase {
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

    func testReturnTargetIsTheModelsActiveWorkspace() {
        let first = model.currentWorkspace.id
        let second = model.createWorkspace(name: "Second", colorId: .ocean)
        model.selectWorkspace(id: second)
        model.selectSettings()
        let controller = SettingsRailController(model: model)
        controller.didEnter(from: first)
        XCTAssertEqual(controller.returnTarget, model.activeWorkspaceId)
        XCTAssertEqual(controller.returnTarget, second, "B1: Settings goes back to AppModel's active workspace")
    }

    func testCreatingAWorkspaceFromSettingsKeepsWhereYouCameFrom() {
        let first = model.currentWorkspace.id
        model.selectSettings()
        let controller = SettingsRailController(model: model)
        controller.view.onAdd?()
        XCTAssertEqual(model.workspaces.count, 2)
        XCTAssertTrue(model.state.isSettingsSelected)
        XCTAssertEqual(controller.returnTarget, first, "the new workspace doesn't become the way back")
        controller.willLeave()
    }

    func testAHiddenSettingsRailSkipsPreferenceReloads() {
        let controller = SettingsRailController(model: model)
        NotificationCenter.default.post(name: .stowAppPreferencesChanged, object: nil)
        XCTAssertTrue(controller.view.tiles.isEmpty, "X5: a Settings rail with no window (sidebar mode) still reloads")
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

    func testADotRightClickPrefersTheContextMenuHook() {
        let alpha = RailView.WorkspaceDot(id: UUID(), name: "Alpha", color: .systemBlue)
        let view = rail([], dots: [alpha])
        var contextMenu: UUID?
        var fallback = 0
        view.onWorkspaceMenu = { _ in fallback += 1 }
        let dot = subviews(of: view, NSButton.self).first { $0.toolTip?.hasPrefix("Alpha") == true }
        XCTAssertEqual(dot?.toolTip, "Alpha · ⌘1", "the dot reports its tip text")
        let click = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        dot?.rightMouseDown(with: click)
        XCTAssertEqual(fallback, 1, "without the hook the old menu shows")
        view.onWorkspaceContextMenu = { id, _ in contextMenu = id }
        dot?.rightMouseDown(with: click)
        XCTAssertEqual(contextMenu, alpha.id)
        XCTAssertEqual(fallback, 1)
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
