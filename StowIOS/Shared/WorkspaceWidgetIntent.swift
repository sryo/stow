import AppIntents
import Foundation
import StowShared

/// A workspace as Edit Widget lists it, plus "Current workspace", which follows whatever
/// is open in the app.
struct WorkspaceEntity: AppEntity, Hashable {
    static let currentID = WorkspaceChoice.currentStorageValue
    static let defaultValue = WorkspaceEntity(id: currentID, name: "Current workspace")

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workspace"
    static let defaultQuery = WorkspaceEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    var choice: WorkspaceChoice { WorkspaceChoice(storageValue: id) }
}

struct WorkspaceEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WorkspaceEntity] {
        Self.entities(for: identifiers, in: AppGroup.makeStore().load())
    }

    func suggestedEntities() async throws -> [WorkspaceEntity] {
        Self.suggestions(from: AppGroup.makeStore().load())
    }

    func defaultResult() async -> WorkspaceEntity? {
        .defaultValue
    }

    static func suggestions(from state: AppState) -> [WorkspaceEntity] {
        [.defaultValue] + state.workspaces.map { WorkspaceEntity(id: $0.id.uuidString, name: $0.name) }
    }

    static func entities(for identifiers: [String], in state: AppState) -> [WorkspaceEntity] {
        let all = suggestions(from: state)
        return identifiers.compactMap { id in all.first(where: { $0.id == id }) }
    }
}

/// The widget's configuration: long-press, Edit Widget, Workspace.
struct SelectWorkspaceIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Workspace"
    static let description = IntentDescription("Choose which workspace this widget shows.")

    @Parameter(title: "Workspace")
    var workspace: WorkspaceEntity?

    init() {}

    init(workspace: WorkspaceEntity?) {
        self.workspace = workspace
    }
}

/// What a widget draws for a given choice.
struct WidgetContent {
    let workspaceName: String
    let colorHex: String?
    let links: [StowShared.Link]

    static func make(choice: WorkspaceChoice?, state: AppState) -> WidgetContent {
        guard let workspace = (choice ?? .current).resolve(in: state) else {
            return WidgetContent(workspaceName: "Stow", colorHex: nil, links: [])
        }
        return WidgetContent(
            workspaceName: workspace.name,
            colorHex: StowTheme.RGB(workspace.colorId.color).hex,
            links: workspace.items.flattenLinks().filter { !$0.isArchived }
        )
    }
}
