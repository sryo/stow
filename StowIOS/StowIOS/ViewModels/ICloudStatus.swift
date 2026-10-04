import CloudKit
import Combine
import Foundation
import StowShared
import UIKit

enum ICloudAccount: Equatable {
    case available, noAccount, restricted, temporarilyUnavailable, unknown

    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        default: self = .unknown
        }
    }
}

/// The one line at the top of Settings. It only turns red when something needs the user.
struct ICloudStatusLine: Equatable {
    enum Action: Equatable { case openSettings, retry }

    let text: String
    let isError: Bool
    let action: Action?

    static func make(account: ICloudAccount, availability: SyncAvailability, lastSync: Date?, lastError: String?, now: Date) -> ICloudStatusLine {
        switch account {
        case .noAccount: return ICloudStatusLine(text: "Not signed in", isError: true, action: .openSettings)
        case .restricted: return ICloudStatusLine(text: "Restricted", isError: true, action: nil)
        case .temporarilyUnavailable: return ICloudStatusLine(text: "Temporarily unavailable", isError: true, action: .openSettings)
        case .available, .unknown: break
        }
        guard availability == .active else {
            return ICloudStatusLine(text: "Off", isError: false, action: nil)
        }
        if lastError != nil {
            return ICloudStatusLine(text: "Couldn't sync", isError: true, action: .retry)
        }
        guard let lastSync else {
            return ICloudStatusLine(text: "Syncing…", isError: false, action: nil)
        }
        return ICloudStatusLine(text: "Synced \(ago(now.timeIntervalSince(lastSync)))", isError: false, action: nil)
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) hr ago"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}

/// Keeps the line current while Settings is open.
@MainActor
final class ICloudStatusMonitor: ObservableObject {
    @Published private(set) var line = ICloudStatusLine(text: "Syncing…", isError: false, action: nil)
    @Published private(set) var lastError: String?

    private var account: ICloudAccount = .unknown
    private var observers: [NSObjectProtocol] = []
    private var ticker: AnyCancellable?

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [CloudSyncManager.statusDidChangeNotification, .CKAccountChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAccount() }
            })
        }
        ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.recompute() }
        refreshAccount()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        ticker = nil
    }

    func performAction() {
        switch line.action {
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .retry:
            CloudSyncManager.shared.fetchChanges()
        case nil:
            break
        }
    }

    private func refreshAccount() {
        recompute()
        guard CloudSyncManager.shared.availability == .active else { return }
        CKContainer(identifier: "iCloud.com.stow.app").accountStatus { [weak self] status, _ in
            Task { @MainActor in
                self?.account = ICloudAccount(status)
                self?.recompute()
            }
        }
    }

    private func recompute() {
        let sync = CloudSyncManager.shared
        lastError = sync.lastSyncError
        line = ICloudStatusLine.make(account: account, availability: sync.availability,
                                     lastSync: sync.lastSyncDate, lastError: sync.lastSyncError, now: Date())
    }
}
