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
        XCTAssertLessThan(icons.rect(of: .tab(0))!.width, 30)
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
        // chip, five entries, ghost, pocket
        XCTAssertEqual(children.count, 8)
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
        }
    }
}
