import SwiftUI
import StowShared

final class StowAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        CloudSyncManager.shared.fetchChanges()
        return .newData
    }
}

@main
struct StowApp: App {
    @UIApplicationDelegateAdaptor(StowAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        CloudSyncManager.shared.fetchChanges()
                    }
                }
        }
    }
}
