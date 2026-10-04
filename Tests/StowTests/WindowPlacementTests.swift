import XCTest
import ServiceManagement
@testable import StowCore

@MainActor
private final class StubLoginItem: LoginItemControlling {
    var status: SMAppService.Status = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

/// "Where Stow lives": the three cards (Floating, On top, Attached) and the edge, mapped
/// onto the dock and Keep on top, and the words each selection shows.
@MainActor
final class WindowPlacementTests: XCTestCase {
    private var accessibility = true
    private var requests = 0
    private var defaults: UserDefaults!

    override func setUp() async throws {
        accessibility = true
        requests = 0
        defaults = scratchDefaults()
    }

    private func makePreferences() -> AppPreferences {
        AppPreferences(defaults: defaults, loginItem: StubLoginItem(),
                       hasAccessibility: { [unowned self] in self.accessibility }, applyTabline: { _ in },
                       requestAccessibility: { [unowned self] in self.requests += 1 })
    }

    // MARK: Card ↔ dock and Keep on top

    func testTheCardFollowsTheDockAndKeepOnTop() {
        XCTAssertEqual(WindowPlacement(dock: .none, keepsOnTop: false, lastEdge: .left).mode, .floating)
        XCTAssertEqual(WindowPlacement(dock: .none, keepsOnTop: true, lastEdge: .left).mode, .onTop)
        for edge in BrowserDock.edges {
            for onTop in [false, true] {
                let placement = WindowPlacement(dock: edge, keepsOnTop: onTop, lastEdge: .left)
                XCTAssertEqual(placement.mode, .attached, "\(edge) is Attached whatever Keep on top says")
                XCTAssertEqual(placement.edge, edge)
                XCTAssertEqual(placement.dock, edge)
            }
        }
    }

    func testANotAttachedPlacementStillDrawsTheLastEdge() {
        let placement = WindowPlacement(dock: .none, keepsOnTop: false, lastEdge: .bottom)
        XCTAssertEqual(placement.edge, .bottom, "the Attached card and the edge picker show the edge you'd get")
        XCTAssertEqual(placement.dock, .none)
        XCTAssertEqual(WindowPlacement(dock: .none, keepsOnTop: false, lastEdge: .none).edge, .left,
                       "never .none: the design starts on the left")
    }

    func testChoosingFloatingOrOnTopDetachesAndSetsKeepOnTop() {
        let preferences = makePreferences()
        preferences.setDock(.right)
        preferences.choose(.onTop)
        XCTAssertEqual(preferences.dock, .none)
        XCTAssertTrue(preferences.keepsOnTop)
        XCTAssertEqual(preferences.placement.mode, .onTop)

        preferences.setDock(.top)
        XCTAssertEqual(preferences.placement.mode, .attached, "the Tabline is Attached too")
        preferences.choose(.floating)
        XCTAssertEqual(preferences.dock, .none, "Floating takes the Tabline away")
        XCTAssertFalse(preferences.keepsOnTop)
        XCTAssertEqual(preferences.placement.mode, .floating)
    }

    func testChoosingAttachedGoesBackToTheLastEdge() {
        let preferences = makePreferences()
        preferences.setDock(.bottom)
        preferences.choose(.floating)
        XCTAssertEqual(preferences.lastEdge, .bottom)
        XCTAssertEqual(preferences.placement.edge, .bottom)
        preferences.choose(.attached)
        XCTAssertEqual(preferences.dock, .bottom)
        XCTAssertEqual(makePreferences().lastEdge, .bottom, "remembered across launches")
    }

    func testChoosingAttachedTheFirstTimeTakesTheSideStowIsOn() {
        let preferences = makePreferences()
        preferences.attachSide = { 0 }
        preferences.choose(.attached)
        XCTAssertEqual(preferences.dock, .left)
        let other = AppPreferences(defaults: scratchDefaults(), loginItem: StubLoginItem(), hasAccessibility: { true },
                                   applyTabline: { _ in }, requestAccessibility: {})
        other.attachSide = { 1 }
        other.choose(.attached)
        XCTAssertEqual(other.dock, .right)
    }

    func testChoosingAnEdgeSetsIt() {
        let preferences = makePreferences()
        for edge in BrowserDock.edges {
            preferences.choose(edge: edge)
            XCTAssertEqual(preferences.dock, edge)
            XCTAssertEqual(preferences.lastEdge, edge)
        }
        preferences.choose(edge: .none)
        XCTAssertEqual(preferences.dock, BrowserDock.bottom, "the edge picker never detaches; the cards do")
    }

    // MARK: Menus and shortcuts stay in step with the cards

    func testWindowMenuMatchesTheCards() {
        let preferences = makePreferences()
        for (dock, onTop, mode) in [(BrowserDock.none, false, AppWindowMode.floating), (.none, true, .onTop),
                                    (.left, false, .attached), (.top, true, .attached), (.bottom, false, .attached)] {
            preferences.choose(onTop ? .onTop : .floating)
            preferences.setDock(dock)
            XCTAssertEqual(preferences.windowMode, mode, "\(dock) / on top \(onTop)")
            XCTAssertEqual(preferences.windowMode, preferences.placement.mode)
        }
    }

    func testOptionCommandTFromTheTablineGoesOnTop() {
        let preferences = makePreferences()
        preferences.setDock(.top)
        preferences.toggleOnTop()
        XCTAssertEqual(preferences.placement.mode, .onTop, "⌥⌘T leaves Attached, Tabline included")
        XCTAssertEqual(preferences.dock, .none)
        preferences.toggleOnTop()
        XCTAssertEqual(preferences.placement.mode, .floating)
    }

    func testOptionCommandLMovesBetweenTheTablineCardAndTheOneBefore() {
        let preferences = makePreferences()
        preferences.choose(.onTop)
        preferences.toggleTabline()
        XCTAssertEqual(preferences.placement, WindowPlacement(dock: .top, keepsOnTop: true, lastEdge: .top))
        preferences.toggleTabline()
        XCTAssertEqual(preferences.placement.mode, .onTop, "back to On top")
    }

    // MARK: Copy

    func testCardWords() {
        typealias C = WindowPlacementCopy
        XCTAssertEqual(AppWindowMode.allCases.map(C.name), ["Floating", "On top", "Attached"])
        XCTAssertEqual(C.meaning(.floating), "A regular window you place anywhere. Other windows can cover it.")
        XCTAssertEqual(C.meaning(.onTop), "A free window that stays above every other app.")
        XCTAssertEqual(C.meaning(.attached), "Glued to your browser window. Moves and resizes with it.")
        XCTAssertEqual(C.example(.floating), "Open Zoom over it and Stow waits behind.")
        XCTAssertEqual(C.example(.onTop), "Stays above Zoom and Figma.")
        XCTAssertEqual(C.example(.attached), "Drag Safari to another display; Stow comes along.")
        XCTAssertEqual(C.ownWindow, "Its own window")
        XCTAssertEqual(C.onBrowser, "On your browser")
        XCTAssertEqual(C.groupTitle, "Where Stow lives")
    }

    func testEdgeWords() {
        typealias C = WindowPlacementCopy
        XCTAssertEqual(BrowserDock.edges.map(C.edgeTitle),
                       ["Sidebar on the left", "Sidebar on the right", "Tabline on top", "Tabline at the bottom"])
        XCTAssertEqual(C.edgeDetail(.left), "Docks to the browser’s left side.")
        XCTAssertEqual(C.edgeDetail(.right), "Docks to the browser’s right side.")
        XCTAssertEqual(C.edgeDetail(.top), "Your tabs ride above the browser’s own.")
        XCTAssertEqual(C.edgeDetail(.bottom), "Your tabs ride under the browser window.")
        XCTAssertEqual(C.edgeHint(.left), "Click the top or bottom edge for the Tabline.")
        XCTAssertEqual(C.edgeHint(.right), "Click the top or bottom edge for the Tabline.")
        XCTAssertEqual(C.edgeHint(.top), "Tabline only rides the top or bottom edge.")
        XCTAssertEqual(C.edgeHint(.bottom), "Tabline only rides the top or bottom edge.")
    }

    func testDescriptionPerSelectionAndPreview() {
        typealias C = WindowPlacementCopy
        let floating = C.description(shown: .floating, selected: .floating, hasAccessibility: true)
        XCTAssertEqual(floating.text, "Floating. A regular window you place anywhere. Other windows can cover it.")
        XCTAssertEqual(floating.example, "Open Zoom over it and Stow waits behind.")
        XCTAssertFalse(floating.isPreview)
        XCTAssertNil(floating.accessibilityNote)

        let hover = C.description(shown: .onTop, selected: .floating, hasAccessibility: true)
        XCTAssertTrue(hover.isPreview, "hovering another card previews it with Click to use")
        XCTAssertEqual(C.previewTag, "CLICK TO USE")
        XCTAssertNil(hover.accessibilityNote)

        let attachHover = C.description(shown: .attached, selected: .floating, hasAccessibility: false)
        XCTAssertEqual(attachHover.accessibilityNote, "Needs Accessibility permission.")
        let attached = C.description(shown: .attached, selected: .attached, hasAccessibility: false)
        XCTAssertNil(attached.accessibilityNote, "once chosen, the warning row says it instead")
    }

    func testWarningAndNoteWords() {
        typealias C = WindowPlacementCopy
        XCTAssertEqual(C.warningTitle(.left), "Attached needs Accessibility.")
        XCTAssertEqual(C.warningTitle(.right), "Attached needs Accessibility.")
        XCTAssertEqual(C.warningTitle(.top), "The Tabline needs Accessibility.")
        XCTAssertEqual(C.warningTitle(.bottom), "The Tabline needs Accessibility.")
        XCTAssertEqual(C.warningDetail, "Stow floats until you allow it.")
        XCTAssertEqual(C.allow, "Allow…")
        XCTAssertEqual(C.noBrowser, "No browser window in front. Stow floats until one is.")
    }

    func testWhatShowsUnderTheCards() {
        typealias S = WindowPlacementStatus
        XCTAssertEqual(S(mode: .floating, hasAccessibility: false, browserInFront: false), .plain,
                       "nothing to warn about when Stow isn't attached")
        XCTAssertEqual(S(mode: .onTop, hasAccessibility: true, browserInFront: false), .plain)
        XCTAssertEqual(S(mode: .attached, hasAccessibility: true, browserInFront: true), .edges)
        XCTAssertEqual(S(mode: .attached, hasAccessibility: false, browserInFront: true), .edgesNeedingAccessibility)
        XCTAssertEqual(S(mode: .attached, hasAccessibility: false, browserInFront: false), .edgesNeedingAccessibility,
                       "the permission comes first")
        XCTAssertEqual(S(mode: .attached, hasAccessibility: true, browserInFront: false), .edgesWithoutBrowser)
    }

    func testPermissionReasonsUseTheCardWords() {
        XCTAssertEqual(AppSheet.permissionNeeds(dock: .left, hasAccessibility: false, automationDenied: nil),
                       [.accessibility(reason: "Attached needs Accessibility")])
        XCTAssertEqual(AppSheet.permissionNeeds(dock: .bottom, hasAccessibility: false, automationDenied: nil),
                       [.accessibility(reason: "The Tabline needs Accessibility")])
    }

    func testTheWindowGroupIsCalledWhereStowLives() {
        XCTAssertEqual(AppSheet.sections.map(\.title), ["Where Stow lives", "Keyboard", "Appearance"])
        XCTAssertEqual(AppSheet.windowRows(dock: .none), [.placement, .openAtLogin], "Keep on top is a card now")
        XCTAssertEqual(AppSheet.windowRows(dock: .top), [.placement, .openAtLogin])
    }
}
