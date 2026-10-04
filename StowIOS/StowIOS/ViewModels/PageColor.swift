import Combine
import Foundation
import StowShared

/// Page color: Full / Soft / None, the same words and the same synced value as the Mac.
enum PageColor {
    struct Option: Hashable {
        let tint: StowTheme.TintMode
        let title: String
    }

    static let options = [
        Option(tint: .full, title: "Full"),
        Option(tint: .subtle, title: "Soft"),
        Option(tint: .off, title: "None"),
    ]

    /// Increase Contrast drops Full to Soft instead of adding another setting.
    static func effective(_ preference: StowTheme.TintMode, increaseContrast: Bool) -> StowTheme.TintMode {
        increaseContrast && preference == .full ? .subtle : preference
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
        tint = preference.tint
        observer = notificationCenter.addObserver(
            forName: SyncedTintPreference.didChangeNotification, object: preference, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tint = self.preference.tint
            }
        }
    }

    func set(_ tint: StowTheme.TintMode) {
        preference.set(tint)
        self.tint = preference.tint
    }
}
