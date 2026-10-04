import XCTest
import StowShared
@testable import StowIOS

/// What the Live Activity draws: one palette on the Lock Screen, and favicons passed
/// by file name.
@MainActor
final class LiveActivityLookTests: XCTestCase {

    private static let colorHexes: [String] =
        WorkspaceColorId.allCases.map { StowTheme.RGB($0.color).hex } + ["#B5F44A", "#C6FF00", "#1A237E", "#000000", "#FFFFFF", "#7F7F7F"]

    // MARK: Lock Screen palette

    func testLockScreenColorsAllComeFromTheLightPalette() {
        for hex in Self.colorHexes {
            let palette = StowTheme.colors(for: .custom(hex)).light
            let style = StowActivityAttributes.LockScreenStyle(colorHex: hex)
            XCTAssertEqual(style.background, palette.surface, hex)
            XCTAssertEqual(style.name, palette.inkPrimary, hex)
            XCTAssertEqual(style.caption, palette.inkSecondary, hex)
            XCTAssertEqual(style.tileFill, palette.paper, hex)
            XCTAssertEqual(style.tileInk, palette.inkPrimary, hex)
            XCTAssertEqual(style.monogramFill, palette.paper, hex)
            XCTAssertEqual(style.monogramInk, palette.inkPrimary, hex)
        }
    }

    func testLockScreenTextMeetsContrastAgainstWhatItSitsOn() {
        for hex in Self.colorHexes {
            let style = StowActivityAttributes.LockScreenStyle(colorHex: hex)
            XCTAssertGreaterThanOrEqual(style.name.contrast(with: style.background), 4.5, "name \(hex)")
            XCTAssertGreaterThanOrEqual(style.caption.contrast(with: style.background), 3, "caption \(hex)")
            XCTAssertGreaterThanOrEqual(style.tileInk.contrast(with: style.tileFill), 4.5, "tile \(hex)")
            XCTAssertGreaterThanOrEqual(style.monogramInk.contrast(with: style.monogramFill), 4.5, "monogram \(hex)")
        }
    }

    // MARK: Favicons

    private var iconsDirectory: URL!

    override func setUp() async throws {
        iconsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stow-la-icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: iconsDirectory)
    }

    private func workspace(linkCount: Int, longURLs: Bool = false) -> Workspace {
        let links: [Node] = (0..<linkCount).map { index in
            let host = "site\(index).example.com"
            let path = longURLs ? "/" + String(repeating: "p", count: 120) + "?q=" + String(repeating: "x", count: 60) : ""
            return .link(StowShared.Link(id: UUID(), title: "A fairly long link title number \(index)",
                                         url: "https://\(host)\(path)", faviconPath: nil))
        }
        return Workspace(id: UUID(), name: "Personal", colorId: .custom("#B5F44A"), items: links)
    }

    private func makeIcons(count: Int) throws {
        for index in 0..<count {
            try Data([0x89, 0x50]).write(to: iconsDirectory.appendingPathComponent("site\(index).example.com.ico"))
        }
    }

    func testStateCarriesTheFaviconFileName() throws {
        try makeIcons(count: 1)
        let state = LiveActivityController.state(for: workspace(linkCount: 2), iconsDirectory: iconsDirectory)
        XCTAssertEqual(state.links[0].iconFile, "site0.example.com.ico")
        XCTAssertNil(state.links[1].iconFile, "no file on disk, so the tile keeps its letter")
    }

    func testIconFileRoundTripsThroughTheEncodedState() throws {
        try makeIcons(count: 1)
        let state = LiveActivityController.state(for: workspace(linkCount: 1), iconsDirectory: iconsDirectory)
        let decoded = try JSONDecoder().decode(StowActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.links.first?.iconFile, "site0.example.com.ico")
    }

    func testOldStatesWithoutIconsStillDecode() throws {
        let json = """
        {"workspaceId":"\(UUID().uuidString)","name":"W","monogram":"W","colorHex":"#FFFFFF","linkCount":1,
         "links":[{"title":"T","url":"https://a.com","host":"a.com"}]}
        """
        let decoded = try JSONDecoder().decode(StowActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(decoded.links.first?.iconFile)
    }

    func testSixLinksWithIconsStayUnderTheActivityKitLimit() throws {
        try makeIcons(count: 6)
        let state = LiveActivityController.state(for: workspace(linkCount: 6), iconsDirectory: iconsDirectory)
        XCTAssertEqual(state.links.count, 6)
        XCTAssertTrue(state.links.allSatisfy { $0.iconFile != nil })
        XCTAssertLessThan(try JSONEncoder().encode(state).count, 4096)
    }

    func testLongURLsStillFitUnderTheLimit() throws {
        try makeIcons(count: 6)
        let state = LiveActivityController.state(for: workspace(linkCount: 6, longURLs: true), iconsDirectory: iconsDirectory)
        XCTAssertLessThan(try JSONEncoder().encode(state).count, 4096)
    }

    func testIconURLResolvesInsideTheContainersIconsFolder() {
        let container = URL(fileURLWithPath: "/tmp/group", isDirectory: true)
        XCTAssertEqual(StowActivityAttributes.iconURL(forFile: "feedly.com.ico", in: container)?.path,
                       "/tmp/group/Icons/feedly.com.ico")
    }

    func testIconURLRejectsNamesThatLeaveTheIconsFolder() {
        let container = URL(fileURLWithPath: "/tmp/group", isDirectory: true)
        for name in ["", ".", "..", "../data.json", "a/b.ico", "/etc/passwd"] {
            XCTAssertNil(StowActivityAttributes.iconURL(forFile: name, in: container), name)
        }
        XCTAssertNil(StowActivityAttributes.iconURL(forFile: nil, in: container))
    }
}
