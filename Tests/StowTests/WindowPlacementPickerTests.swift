import XCTest
@testable import StowCore

/// The "Where Stow lives" cards: what each selection shows, the keyboard, VoiceOver and
/// the looping pictures.
@MainActor
final class WindowPlacementPickerTests: XCTestCase {
    private func makePicker(_ placement: WindowPlacement = WindowPlacement(dock: .none, keepsOnTop: false, lastEdge: .left),
                            width: CGFloat = 252, reduceMotion: Bool = false) -> WindowPlacementPicker {
        let picker = WindowPlacementPicker()
        picker.reduceMotion = { reduceMotion }
        picker.placement = placement
        picker.frame = NSRect(x: 0, y: 0, width: width, height: picker.height(forWidth: width))
        picker.layoutSubtreeIfNeeded()
        return picker
    }

    private func attached(_ edge: BrowserDock) -> WindowPlacement {
        WindowPlacement(dock: edge, keepsOnTop: false, lastEdge: edge)
    }

    // MARK: What shows

    func testTheEdgePickerAppearsOnlyForAttached() {
        let picker = makePicker()
        XCTAssertFalse(picker.isEdgePickerVisible)
        picker.placement = WindowPlacement(dock: .none, keepsOnTop: true, lastEdge: .left)
        XCTAssertFalse(picker.isEdgePickerVisible)
        for edge in BrowserDock.edges {
            picker.placement = attached(edge)
            XCTAssertTrue(picker.isEdgePickerVisible)
            XCTAssertEqual(picker.edgePicker.dock, edge)
        }
    }

    func testTheWarningAndTheNoBrowserNote() {
        let picker = makePicker(attached(.left))
        XCTAssertFalse(picker.isWarningVisible)
        XCTAssertFalse(picker.isNoteVisible)
        picker.hasAccessibility = false
        XCTAssertTrue(picker.isWarningVisible)
        XCTAssertFalse(picker.isNoteVisible)
        XCTAssertEqual(picker.warningTitle, "Attached needs Accessibility.")
        picker.placement = attached(.top)
        XCTAssertEqual(picker.warningTitle, "The Tabline needs Accessibility.")
        picker.hasAccessibility = true
        picker.browserInFront = false
        XCTAssertFalse(picker.isWarningVisible)
        XCTAssertTrue(picker.isNoteVisible)
        picker.placement = WindowPlacement(dock: .none, keepsOnTop: false, lastEdge: .top)
        XCTAssertFalse(picker.isNoteVisible, "a floating Stow doesn't need a browser")
    }

    func testMissingAccessibilityBadgesTheAttachedCardAndDashesItsPicture() {
        let picker = makePicker()
        picker.hasAccessibility = false
        XCTAssertEqual(picker.cards.map(\.showsBadge), [false, false, true], "the ! warns before you choose")
        XCTAssertFalse(picker.cards[2].illustration.isWaiting, "not chosen yet, so not drawn waiting")
        picker.placement = attached(.left)
        XCTAssertTrue(picker.cards[2].illustration.isWaiting, "chosen: dashed amber with a gap")
        XCTAssertTrue(picker.edgePicker.isWaiting)
    }

    func testTheAttachedCardDrawsTheChosenEdge() {
        let picker = makePicker(attached(.bottom))
        XCTAssertEqual(picker.cards.map(\.illustration.mode), [.floating, .onTop, .attached])
        XCTAssertEqual(picker.cards[2].illustration.edge, .bottom)
        picker.placement = WindowPlacement(dock: .none, keepsOnTop: false, lastEdge: .right)
        XCTAssertEqual(picker.cards[2].illustration.edge, .right)
    }

    func testCardsBecomeRowsAtThePageWidth() {
        let sheet = makePicker(width: 252)
        XCTAssertFalse(sheet.usesRows, "276pt sheet: three cards in a row")
        let page = makePicker(width: 328)
        XCTAssertTrue(page.usesRows, "340pt page: rows with the caption always visible")
        XCTAssertEqual(page.cards.map(\.frame.width), [328, 328, 328])
        XCTAssertEqual(sheet.cards.map(\.frame.width), [80, 80, 80])
        XCTAssertEqual(sheet.cards.map(\.frame.minX), [0, 86, 172])
    }

    func testSheetGeometryMatchesTheDesign() {
        let picker = makePicker()
        // .brk 16pt (its own window 164pt, on your browser 82pt), 6pt gap less 1, cards 75pt.
        XCTAssertEqual(picker.bracketFrames.own, NSRect(x: 0, y: 0, width: 164, height: 16))
        XCTAssertEqual(picker.bracketFrames.browser, NSRect(x: 170, y: 0, width: 82, height: 16))
        XCTAssertEqual(picker.cards[0].frame, NSRect(x: 0, y: 21, width: 80, height: 75))
        XCTAssertEqual(picker.cards[0].illustration.frame, NSRect(x: 4, y: 4, width: 72, height: 48))
        // Description: 7pt below; Floating takes 61pt (two lines, 1pt, two lines), as in the design.
        XCTAssertEqual(picker.height(forWidth: 252), 96 + 7 + 61, accuracy: 1)
    }

    func testPageGeometryMatchesTheDesign() {
        let picker = makePicker(width: 308)
        // .rsub 6+12+3, rows 5pt padding with a 90×60 picture, 2pt apart.
        XCTAssertEqual(picker.cards[0].illustration.frame.size, NSSize(width: 90, height: 60))
        XCTAssertEqual(picker.cards[0].illustration.frame.minX, 5)
        XCTAssertEqual(picker.cards[0].frame.minY, 23)
        XCTAssertEqual(picker.cards[0].frame.height, 103, accuracy: 2)
        XCTAssertEqual(picker.cards[1].frame.height, 73, accuracy: 2)
        XCTAssertEqual(picker.cards[2].frame.height, 88, accuracy: 2)
    }

    // MARK: Choosing

    func testClickingACardChoosesIt() {
        let picker = makePicker()
        var chosen: [AppWindowMode] = []
        picker.onChoose = { chosen.append($0) }
        picker.cards[1].mouseDown(with: mouseEvent())
        picker.cards[1].mouseUp(with: mouseEvent())
        picker.choose(.attached)
        XCTAssertEqual(chosen, [.onTop, .attached])
    }

    func testArrowKeysMoveAndSelectLikeARadioGroup() {
        let picker = makePicker()
        var chosen: [AppWindowMode] = []
        picker.onChoose = { mode in
            chosen.append(mode)
            picker.placement = WindowPlacement(dock: mode == .attached ? .left : .none, keepsOnTop: mode == .onTop, lastEdge: .left)
        }
        XCTAssertTrue(picker.becomeFirstResponder())
        XCTAssertEqual(picker.focusedMode, .floating, "focus lands on the chosen card")
        picker.handleKey(.right)
        picker.handleKey(.down)
        picker.handleKey(.right)
        picker.handleKey(.left)
        picker.handleKey(.up)
        XCTAssertEqual(chosen, [.onTop, .attached, .floating, .attached, .onTop], "→ ↓ next, ← ↑ back, wrapping")
        XCTAssertEqual(picker.focusedMode, .onTop)
        picker.handleKey(.select)
        XCTAssertEqual(chosen.last, .onTop, "Space and Return choose the focused card")
        picker.keyDown(with: keyEvent(124))
        XCTAssertEqual(chosen.last, .attached, "→ through keyDown")
        picker.keyDown(with: keyEvent(49))
        XCTAssertEqual(chosen.last, .attached)
    }

    func testTabReachesTheEdgesOnceAttachedAndArrowsOnAllowStayThere() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let picker = makePicker()
        window.contentView?.addSubview(picker)
        var chosen: [AppWindowMode] = []
        picker.onChoose = { chosen.append($0) }
        picker.hasAccessibility = false
        picker.placement = attached(.left)
        picker.frame.size.height = picker.height(forWidth: 252)
        picker.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(picker.nextValidKeyView === picker.edgePicker, "Tab goes from the cards to the edges")
        XCTAssertTrue(picker.edgePicker.nextValidKeyView is PlacementButton, "then to Allow…")
        let allow = try XCTUnwrap(picker.edgePicker.nextValidKeyView)
        window.makeFirstResponder(allow)
        allow.keyDown(with: keyEvent(126))
        XCTAssertEqual(chosen, [], "↑ on Allow… doesn't change the card")
    }

    func testVoiceOverSeesThreeRadioButtons() {
        let picker = makePicker(WindowPlacement(dock: .none, keepsOnTop: true, lastEdge: .left))
        XCTAssertEqual(picker.accessibilityRole(), .radioGroup)
        XCTAssertEqual(picker.accessibilityLabel(), "Where Stow lives")
        let cards = picker.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []
        XCTAssertEqual(cards.map { $0.accessibilityLabel() ?? "" }, ["Floating", "On top", "Attached"])
        XCTAssertTrue(cards.allSatisfy { $0.accessibilityRole() == .radioButton })
        XCTAssertEqual(cards.map { ($0.accessibilityValue() as? Bool) ?? false }, [false, true, false])
        XCTAssertEqual(cards[0].accessibilityHelp(), "A regular window you place anywhere. Other windows can cover it.")
        picker.hasAccessibility = false
        XCTAssertEqual(cards[2].accessibilityHelp(),
                       "Glued to your browser window. Moves and resizes with it. Needs Accessibility permission.")
        var chosen: [AppWindowMode] = []
        picker.onChoose = { chosen.append($0) }
        XCTAssertTrue(cards[2].accessibilityPerformPress())
        XCTAssertEqual(chosen, [.attached])
        XCTAssertTrue(picker.cards.allSatisfy { !$0.illustration.isAccessibilityElement() }, "the art is decoration")
    }

    // MARK: Hover

    func testHoveringACardPreviewsIt() {
        let picker = makePicker()
        XCTAssertEqual(picker.descriptionShown.text, "Floating. A regular window you place anywhere. Other windows can cover it.")
        picker.hover(.onTop)
        XCTAssertTrue(picker.descriptionShown.isPreview)
        XCTAssertTrue(picker.descriptionShown.text.hasPrefix("On top."))
        XCTAssertTrue(picker.cards[1].isHovered)
        picker.hover(nil)
        XCTAssertFalse(picker.descriptionShown.isPreview, "moving away restores the chosen card")
        picker.hover(.floating)
        XCTAssertFalse(picker.descriptionShown.isPreview, "the chosen card doesn't say Click to use")
    }

    func testHoveringNeverShrinksTheSheetUnderThePointer() {
        let picker = makePicker()
        let resting = picker.height(forWidth: 252)
        picker.pointerMoved(inside: true)
        picker.hover(.onTop)
        XCTAssertEqual(picker.height(forWidth: 252), resting, "On top's shorter caption keeps Floating's height")
        picker.hover(nil)
        XCTAssertEqual(picker.height(forWidth: 252), resting)
        picker.pointerMoved(inside: false)
        picker.placement = WindowPlacement(dock: .none, keepsOnTop: true, lastEdge: .left)
        XCTAssertLessThan(picker.height(forWidth: 252), resting, "once the pointer leaves, On top's own height")
    }

    // MARK: Motion

    func testTheChosenAndHoveredCardsLoopAndTheOthersHoldTheirKeyFrame() {
        let picker = makePicker()
        XCTAssertEqual(picker.cards.map(\.illustration.isAnimating), [true, false, false])
        picker.hover(.attached)
        XCTAssertEqual(picker.cards.map(\.illustration.isAnimating), [true, false, true])
        picker.hover(nil)
        picker.placement = WindowPlacement(dock: .none, keepsOnTop: true, lastEdge: .left)
        XCTAssertEqual(picker.cards.map(\.illustration.isAnimating), [false, true, false])
    }

    func testReduceMotionStopsTheLoops() {
        let picker = makePicker(reduceMotion: true)
        picker.hover(.attached)
        XCTAssertEqual(picker.cards.map(\.illustration.isAnimating), [false, false, false])
        for card in picker.cards {
            XCTAssertNil(card.illustration.layer?.animationKeys(), "no loop is running")
        }
        XCTAssertTrue(picker.cards.allSatisfy { $0.illustration.showsKeyFrame }, "a still frame that explains each mode")
    }

    func testTheLoopTimingMatchesTheDesign() {
        let illustration = PlacementIllustration()
        illustration.mode = .floating
        XCTAssertEqual(PlacementIllustration.loopDuration, 4.6)
        XCTAssertEqual(PlacementIllustration.keyFrameTime, 2.2)
        // intr: 0–12% off to the right (86), 34–64% over Stow (0), 86–100% gone again.
        XCTAssertEqual(PlacementIllustration.intruderOffset(at: 0), 86)
        XCTAssertEqual(PlacementIllustration.intruderOffset(at: 0.12 * 4.6), 86, accuracy: 0.01)
        XCTAssertEqual(PlacementIllustration.intruderOffset(at: 2.2), 0)
        XCTAssertEqual(PlacementIllustration.intruderOffset(at: 0.23 * 4.6), 43, accuracy: 0.5, "ease-in-out midpoint")
        XCTAssertEqual(PlacementIllustration.intruderOffset(at: 0.9 * 4.6), 86)
        // glue: none → translate(-8,5) scale(.84) about (60,14) between 36% and 64%.
        XCTAssertEqual(PlacementIllustration.glue(at: 2.2).scale, 0.84, accuracy: 0.001)
        XCTAssertEqual(PlacementIllustration.glue(at: 0).scale, 1)
        // cur: hidden to 8%, shown 12–88%, gone by 94%.
        XCTAssertEqual(PlacementIllustration.cursorOpacity(at: 0.05 * 4.6), 0)
        XCTAssertEqual(PlacementIllustration.cursorOpacity(at: 2.2), 1)
        XCTAssertEqual(PlacementIllustration.cursorOpacity(at: 0.97 * 4.6), 0)
    }

    func testTheRunningLoopStartsOnTheKeyFrame() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let picker = makePicker()
        window.contentView?.addSubview(picker)
        picker.refreshMotion()
        let floating = picker.cards[0].illustration
        let keys = floating.runningAnimationKeys
        XCTAssertFalse(keys.isEmpty, "the chosen card's loop is running")
        let animation = try XCTUnwrap(floating.intruderAnimation)
        XCTAssertEqual(animation.duration, 4.6)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertEqual(animation.timeOffset, 2.2, "picks up from the frame it was frozen on")
        XCTAssertEqual(animation.keyTimes, [0, 0.12, 0.34, 0.64, 0.86, 1])
    }

    // MARK: Allow

    func testAllowRunsTheCallback() {
        let picker = makePicker(attached(.left))
        picker.hasAccessibility = false
        var allowed = 0
        picker.onAllow = { allowed += 1 }
        picker.allow()
        XCTAssertEqual(allowed, 1)
    }

    private func keyEvent(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)!
    }

    private func mouseEvent() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
