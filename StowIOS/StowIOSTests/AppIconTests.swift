import XCTest
import UIKit
@testable import StowIOS

/// The app ships the Mac's Icon Composer icon, compiled into its asset catalog.
final class AppIconTests: XCTestCase {

    func testInfoPlistNamesThePrimaryIcon() {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        XCTAssertEqual(primary?["CFBundleIconName"] as? String, "AppIcon")
    }

    func testTheAssetCatalogIsBundled() {
        XCTAssertNotNil(Bundle.main.url(forResource: "Assets", withExtension: "car"))
    }
}
