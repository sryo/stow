import XCTest
@testable import StowCore

/// Attached mode follows whichever browser you bring forward, and still steps aside for
/// every other app.
final class AttachmentActivationTests: XCTestCase {
    private let browsers: Set<String> = ["com.google.Chrome.canary", "company.thebrowser.Browser"]
    private let stow = "com.stow.app"

    private func respond(to app: String, current: String, last: String?) -> AttachmentActivation.Response {
        AttachmentActivation.respond(to: app, currentBrowser: current, lastFrontmost: last,
                                     stow: stow, isBrowser: { self.browsers.contains($0) })
    }

    func testTheAttachedBrowserComingForwardAttaches() {
        XCTAssertEqual(respond(to: "com.google.Chrome.canary", current: "com.google.Chrome.canary", last: nil),
                       .attach("com.google.Chrome.canary"))
    }

    func testAnotherBrowserComingForwardMovesTheAttachmentToIt() {
        XCTAssertEqual(respond(to: "company.thebrowser.Browser", current: "com.google.Chrome.canary",
                               last: "com.google.Chrome.canary"),
                       .attach("company.thebrowser.Browser"))
    }

    func testANonBrowserAppHides() {
        XCTAssertEqual(respond(to: "com.apple.finder", current: "com.google.Chrome.canary",
                               last: "com.google.Chrome.canary"), .hide)
    }

    func testStowFromTheBrowserStaysVisible() {
        XCTAssertEqual(respond(to: stow, current: "company.thebrowser.Browser", last: "company.thebrowser.Browser"),
                       .keep)
    }

    func testStowFromANonBrowserAppHides() {
        XCTAssertEqual(respond(to: stow, current: "company.thebrowser.Browser", last: "com.apple.finder"), .hide)
    }
}
