import Combine
import Foundation
import StowShared

/// Page color: Color or Neutral, stored as the Mac's synced "full" and "off".
enum PageColor {
    struct Option: Hashable {
        let tint: StowTheme.TintMode
        let title: String
    }

    static let options = [
        Option(tint: .full, title: "Color"),
        Option(tint: .off, title: "Neutral"),
    ]

    /// The retired Soft ("subtle", still stored by older Macs) shows and draws as Color.
    static func shown(_ preference: StowTheme.TintMode) -> StowTheme.TintMode {
        preference == .subtle ? .full : preference
    }
}

/// Publishes the synced page color so every page redraws when it changes here or on the Mac.
@MainActor
final class PageColorStore: ObservableObject {
    @Published private(set) var tint: StowTheme.TintMode

    private let preference: SyncedTintPreference
    private var observer: NSObjectProtocol?

    init(preference: SyncedTintPreference, notificationCenter: NotificationCenter = .default) {
        self.preference = preference
        tint = PageColor.shown(preference.tint)
        observer = notificationCenter.addObserver(
            forName: SyncedTintPreference.didChangeNotification, object: preference, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tint = PageColor.shown(self.preference.tint)
            }
        }
    }

    func set(_ tint: StowTheme.TintMode) {
        preference.set(tint)
        self.tint = PageColor.shown(preference.tint)
    }
}
