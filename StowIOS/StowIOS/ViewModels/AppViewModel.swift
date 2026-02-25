import SwiftUI
import StowShared

@MainActor
final class AppViewModel: ObservableObject {
    let model: AppModel
    @Published var refreshTrigger = false

    init() {
        let model = AppModel()
        self.model = model
        model.onChange = { [weak self] in
            self?.refreshTrigger.toggle()
            CloudSyncManager.shared.scheduleLocalChanges()
        }

        // Initialize iCloud sync
        CloudSyncManager.shared.configure(model: model)
    }

    var workspaces: [Workspace] {
        model.workspaces
    }

    var currentWorkspace: Workspace {
        model.currentWorkspace
    }

    var selectedWorkspaceId: UUID? {
        get { model.state.selectedWorkspaceId }
        set {
            if let id = newValue {
                model.selectWorkspace(id: id)
            }
        }
    }

    func selectWorkspace(id: UUID) {
        model.selectWorkspace(id: id)
    }

    func createWorkspace(name: String) {
        model.createWorkspace(name: name, colorId: .randomColor())
    }

    func deleteWorkspace(id: UUID) {
        model.deleteWorkspace(id: id)
    }
}
