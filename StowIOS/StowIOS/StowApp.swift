import SwiftUI
import StowShared

final class StowAppDelegate: NSObject, UIApplicationDelegate {
    weak var viewModel: AppViewModel?

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // A share saved while the app sat in the background must be in memory before the
        // merge below saves, or that save would drop it.
        viewModel?.absorbSharedLinks()
        CloudSyncManager.shared.fetchChanges()
        return .newData
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Sync falls back to the 30-second poll timer; log so the degraded
        // mode is diagnosable instead of silent.
        NSLog("Stow: push registration failed, sync falls back to polling — \(error.localizedDescription)")
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
                .onAppear {
                    appDelegate.viewModel = viewModel
                    viewModel.refreshLiveActivity()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        viewModel.absorbSharedLinks()
                        CloudSyncManager.shared.fetchChanges()
                        viewModel.refreshLiveActivity(force: true)
                    }
                }
                .onOpenURL { url in
                    if let target = StowActivityAttributes.target(ofDeepLink: url) {
                        UIApplication.shared.open(target)
                    } else if let id = try? viewModel.model.importSharedLink(url) {
                        viewModel.model.selectWorkspace(id: id)
                    }
                }
        }
    }
}
