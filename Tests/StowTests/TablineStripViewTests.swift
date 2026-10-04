import XCTest
@testable import StowCore

/// Layout tiers of the Tabline strip, using the approved mockup's "Research" set.
/// With `TABLINE_RENDER_DIR` set, also writes light and dark PNGs of the strip there
/// for side-by-side comparison with the mockup.
@MainActor
final class TablineStripViewTests: XCTestCase {
    private func link(_ title: String, _ url: String) -> Link {
        Link(id: UUID(), title: title, url: url, faviconPath: nil)
    }

    private func researchModel() -> TablineStripModel {
        let refs = [link("Apple HIG", "https://developer.apple.com/design"), link("Figma", "https://figma.com"),
                    link("Practical Typography", "https://practicaltypography.com")]
        let folder = Folder(id: UUID(), name: "Design refs", children: refs.map { .link($0) }, isExpanded: false)
        var model = TablineStripModel()
        model.name = "Research"
        model.colorId = .ocean
        model.entries = [.link(link("Linear", "https://linear.app")), .link(link("GitHub", "https://github.com")),
                         .group(folder, links: refs), .link(link("Vercel", "https://vercel.com")),
                         .link(link("Calendar", "https://calendar.google.com"))]
        model.raisedIndex = 1
        model.liveIndices = [0, 1, 4]
        model.ghost = TablineGhost(url: URL(string: "https://developer.mozilla.org/en-US/docs/Web/API/Popover_API")!,
                                   title: "MDN · Popover API", host: "developer.mozilla.org")
        model.pocketCount = 3
        return model
    }

    private func strip(width: CGFloat) -> TablineStripView {
        let view = TablineStripView(frame: NSRect(x: 0, y: 0, width: width, height: 32))
        view.update(researchModel())
        return view
    }

    func testWideStripShowsEveryEntry() {
        let view = strip(width: 1100)
        XCTAssertTrue(view.hiddenEntryIndices.isEmpty)
        XCTAssertNotNil(view.rect(of: .ghost))
        XCTAssertNotNil(view.rect(of: .pocket))
        XCTAssertEqual(view.rect(of: .pocket)?.maxX, 1100 - 5)
    }

    func testNarrowStripCompressesBeforeOverflowing() {
        // Icons only still fit at the mockup's 514pt.
        let icons = strip(width: 514)
        XCTAssertTrue(icons.hiddenEntryIndices.isEmpty)
        // Some entries are down to their icons; the spare width titles the rest, the raised one first.
        XCTAssertTrue([0, 1, 3, 4].contains { icons.rect(of: .tab($0))!.width < 30 })
        XCTAssertTrue(icons.isTitled(.tab(1)))
        // Narrower than that, trailing entries fold into "+n".
        let tight = strip(width: 300)
        XCTAssertFalse(tight.hiddenEntryIndices.isEmpty)
        XCTAssertNotNil(tight.rect(of: .overflow))
    }

    func testGhostLabelUsesTheSiteName() {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(TablineGhost(url: url, title: "MDN · Popover API", host: "developer.mozilla.org").label, "Stow MDN")
        XCTAssertEqual(TablineGhost(url: url, title: "Linear – Plan and build", host: "linear.app").label, "Stow Linear")
        XCTAssertEqual(TablineGhost(url: url, title: "A page title without a site name", host: "example.com").label, "Stow example.com")
    }

    func testEveryStripPartIsAVoiceOverButton() {
        let view = strip(width: 1100)
        let children = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        // gear, chip, five entries, ghost, pocket
        XCTAssertEqual(children.count, 9)
        XCTAssertTrue(children.allSatisfy { $0.accessibilityRole() == .button })
        let labels = children.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains { $0.hasPrefix("GitHub") }, "labels: \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("open in browser") && $0.hasPrefix("Linear") }, "labels: \(labels)")
        XCTAssertFalse(labels.contains { $0.contains("open in browser") && $0.hasPrefix("Vercel") }, "labels: \(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Design refs") }, "labels: \(labels)")
        // Each element's frame is the drawn part, in screen space via the strip.
        let tab = view.rect(of: .tab(1))!
        guard let github = children.first(where: { $0.accessibilityLabel()?.hasPrefix("GitHub") == true }) else {
            return XCTFail("no GitHub element")
        }
        XCTAssertEqual(github.accessibilityFrameInParentSpace(), tab)
    }

    func testStripElementsOutliveTheCallThatReturnedThem() {
        // VoiceOver asks for the children, then asks each one for its role and label. An
        // element nothing keeps is gone by then, and every query fails as invalid.
        let view = strip(width: 1100)
        weak var first: NSAccessibilityElement?
        autoreleasepool {
            first = view.accessibilityChildren()?.first as? NSAccessibilityElement
        }
        XCTAssertNotNil(first, "the strip must hold on to its accessibility elements")
        let again = view.accessibilityChildren()?.first as? NSAccessibilityElement
        XCTAssertTrue(first === again, "the same part keeps the same element between queries")
    }

    func testStripHasNoSearchTool() {
        let view = strip(width: 1100)
        let labels = (view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        XCTAssertFalse(labels.contains { $0.hasPrefix("Search") }, "labels: \(labels)")
    }

    func testPressingAStripElementActivatesThatPart() {
        let view = strip(width: 1100)
        var activated: TablineStripView.Kind?
        view.onActivate = { kind, _ in activated = kind }
        let children = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        let github = children.first { $0.accessibilityLabel()?.hasPrefix("GitHub") == true }
        XCTAssertEqual(github?.accessibilityPerformPress(), true)
        XCTAssertEqual(activated, .tab(1))
    }

    /// The user's live strip: a "Personal" chip, 18 sites and a folder.
    private func personalModel() -> TablineStripModel {
        // Saved page titles run long, so even short names (52pt each) don't all fit.
        let titles = ["Elastic Cloud Console", "Mastodon Home Timeline", "Readwise Reader Library", "Google Drive My Files",
                      "Instagram Direct Inbox", "Feedly Today Feed", "X Home Timeline", "Figma Recent Files",
                      "YouTube Subscriptions", "LinkedIn Feed Updates", "Printables Models Feed", "Letterboxd Diary Films",
                      "Linear Inbox Issues", "Phone Calls Recents", "Torrent Web Client", "Kagi Search Settings",
                      "GitHub Notifications", "Popcorn Time Movies"]
        let refs = [link("Arc", "https://arc.net"), link("Figma", "https://figma.com"), link("Are.na", "https://are.na")]
        let folder = Folder(id: UUID(), name: "Tools", children: refs.map { .link($0) }, isExpanded: false)
        var model = TablineStripModel()
        model.name = "Personal"
        model.colorId = .defaultColor()
        model.entries = titles.map { .link(link($0, "https://\($0.lowercased().replacingOccurrences(of: " ", with: "")).com")) }
            + [.group(folder, links: refs)]
        model.raisedIndex = 3
        model.liveIndices = Set(0..<18)
        return model
    }

    func testGearLeadsTheStripAndIsASettingsButton() {
        let view = strip(width: 1100)
        let gear = try! XCTUnwrap(view.rect(of: .gear))
        let chip = try! XCTUnwrap(view.rect(of: .chip))
        XCTAssertEqual(gear.minX, 5)
        XCTAssertLessThan(gear.maxX, chip.minX)
        var activated: TablineStripView.Kind?
        view.onActivate = { kind, _ in activated = kind }
        let children = (view.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        let element = children.first { $0.accessibilityLabel() == "Settings" }
        XCTAssertEqual(element?.accessibilityPerformPress(), true)
        XCTAssertEqual(activated, .gear)
    }

    func testNineteenEntriesUseMostOf1650Points() {
        let view = TablineStripView(frame: NSRect(x: 0, y: 0, width: 1650, height: 32))
        view.update(personalModel())
        XCTAssertTrue(view.hiddenEntryIndices.isEmpty)
        let rects = (0..<19).compactMap { view.rect(of: .tab($0)) ?? view.rect(of: .group($0)) }
        XCTAssertEqual(rects.count, 19)
        XCTAssertGreaterThan(rects.last!.maxX, 1650 * 0.85, "the right half isn't left empty")
        let titled = (0..<18).filter { view.isTitled(.tab($0)) }
        XCTAssertGreaterThan(titled.count, 9, "titles where they fit: \(titled)")
        XCTAssertTrue(view.isTitled(.tab(3)), "the raised page keeps its title")
    }

    func testRightClickOnTheChipAsksForTheWorkspaceMenu() {
        let view = strip(width: 1100)
        var asked: TablineStripView.Kind?
        view.onContextMenu = { kind, _ in asked = kind }
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = view
        let chip = view.rect(of: .chip)!
        let point = view.convert(NSPoint(x: chip.midX, y: chip.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.rightMouseDown(with: event)
        XCTAssertEqual(asked, .chip)
    }

    func testRenderForComparison() throws {
        guard let dir = ProcessInfo.processInfo.environment["TABLINE_RENDER_DIR"] else { throw XCTSkip("TABLINE_RENDER_DIR not set") }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for width in [CGFloat(1100), 760, 514] {
                let view = strip(width: width)
                view.appearance = NSAppearance(named: appearance)
                // 2x, to match the mockup screenshots.
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * 2, pixelsHigh: 64, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("render_\(name)_\(Int(width)).png"))
            }
            for width in [CGFloat(1650), 900] {
                let view = TablineStripView(frame: NSRect(x: 0, y: 0, width: width, height: 32))
                view.update(personalModel())
                view.appearance = NSAppearance(named: appearance)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * 2, pixelsHigh: 64, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("personal_\(name)_\(Int(width)).png"))
            }
        }
    }
}
