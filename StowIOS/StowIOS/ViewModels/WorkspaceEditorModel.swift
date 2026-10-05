import Foundation
import UIKit
import StowShared

/// The Edit Workspace sheet, the iPhone's copy of the Mac's workspace editor: name,
/// color, icon, then Open, Share…, Export… and Delete.
///
/// Editing a workspace changes it as you go, like the Mac's editor, except a custom color:
/// the color picker's ticks only preview, and the last one lands when the sheet closes.
/// A new workspace is only a draft until `commit()`; closing the sheet any other way
/// creates nothing.
@MainActor
final class WorkspaceEditorModel: ObservableObject, Identifiable {
    enum Mode: Equatable {
        case create
        case edit(UUID)
    }

    struct IconChoice: Equatable {
        let title: String
        let style: WorkspaceIcon
    }

    static let presetColors = WorkspaceColorId.allCases
    static let iconChoices = [
        IconChoice(title: "Favicons", style: .favicons),
        IconChoice(title: "Letter", style: .letter),
        IconChoice(title: "Symbol", style: .symbol("star")),
    ]
    static let symbols = WorkspaceTileIdentity.symbols

    let id = UUID()
    let mode: Mode
    private let model: AppModel
    private let hasIcon: (StowShared.Link) -> Bool
    private var hasPendingCustomColor = false
    private var isClosed = false
    /// The workspace `commit()` created.
    private(set) var createdId: UUID?

    @Published var name: String {
        didSet { renameIfEditing() }
    }
    @Published private(set) var colorId: WorkspaceColorId
    @Published private(set) var icon: WorkspaceIcon
    /// The symbol the Symbol choice comes back to.
    @Published private(set) var selectedSymbol: String

    convenience init(creatingIn model: AppModel) {
        self.init(creatingIn: model, hasIcon: Self.hasIconOnThisPhone)
    }

    init(creatingIn model: AppModel, hasIcon: @escaping (StowShared.Link) -> Bool) {
        self.mode = .create
        self.model = model
        self.hasIcon = hasIcon
        name = ""
        colorId = WorkspaceColorAllocator.next(existing: model.workspaces.map(\.colorId))
        icon = .favicons
        selectedSymbol = "star"
    }

    convenience init(editing workspaceId: UUID, in model: AppModel) {
        self.init(editing: workspaceId, in: model, hasIcon: Self.hasIconOnThisPhone)
    }

    init(editing workspaceId: UUID, in model: AppModel, hasIcon: @escaping (StowShared.Link) -> Bool) {
        self.mode = .edit(workspaceId)
        self.model = model
        self.hasIcon = hasIcon
        let workspace = model.workspaces.first { $0.id == workspaceId }
        name = workspace?.name ?? ""
        colorId = workspace?.colorId ?? .defaultColor()
        icon = workspace?.icon ?? .favicons
        if case .symbol(let symbol) = workspace?.icon { selectedSymbol = symbol } else { selectedSymbol = "star" }
    }

    /// Swiping past the last page asks for a new workspace; it doesn't make one.
    static func forOverSwipe(in model: AppModel) -> WorkspaceEditorModel {
        WorkspaceEditorModel(creatingIn: model)
    }

    /// A favicon counts when its file is in this iPhone's icon folder.
    private static func hasIconOnThisPhone(_ link: StowShared.Link) -> Bool {
        FaviconStorage.fileName(for: link, in: AppGroup.iconsDirectory) != nil
    }

    // MARK: State

    var isNew: Bool { mode == .create }
    var title: String { isNew ? "New Workspace" : "Edit Workspace" }
    var focusesName: Bool { isNew }
    var workspaceId: UUID? {
        if case .edit(let id) = mode { return id }
        return nil
    }
    private var workspace: Workspace? {
        workspaceId.flatMap { id in model.workspaces.first { $0.id == id } }
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canCommit: Bool { isNew && !trimmedName.isEmpty && !isClosed }
    var canDelete: Bool { !isNew && model.workspaces.count > 1 }
    var isCustomColor: Bool {
        if case .custom = colorId { return true }
        return false
    }
    var itemCount: Int { workspace?.items.activeItemCount() ?? 0 }
    var shareURL: URL? {
        guard let id = workspaceId, let string = try? model.shareWorkspace(id: id) else { return nil }
        return URL(string: string)
    }

    // MARK: Previews

    /// What the badge shows with the draft's name and icon, letters resolved among every
    /// workspace so they stay distinct.
    var preview: WorkspaceTileIdentity { identity(with: icon) }
    var faviconsPreview: WorkspaceTileIdentity { identity(with: .favicons) }
    var letterPreview: WorkspaceTileIdentity { identity(with: .letter) }
    var symbolPreview: WorkspaceTileIdentity { .symbol(selectedSymbol) }

    func preview(for choice: IconChoice) -> WorkspaceTileIdentity {
        switch choice.style {
        case .favicons: return faviconsPreview
        case .letter: return letterPreview
        case .symbol: return symbolPreview
        }
    }

    func isChosen(_ choice: IconChoice) -> Bool {
        switch (choice.style, icon) {
        case (.favicons, .favicons), (.letter, .letter), (.symbol, .symbol): return true
        default: return false
        }
    }

    private func identity(with icon: WorkspaceIcon) -> WorkspaceTileIdentity {
        let draftId = workspaceId ?? id
        var workspaces = model.workspaces
        let draftName = trimmedName.isEmpty ? (workspace?.name ?? "") : trimmedName
        if let index = workspaces.firstIndex(where: { $0.id == draftId }) {
            workspaces[index].name = draftName
            workspaces[index].icon = icon
        } else {
            workspaces.append(Workspace(id: draftId, name: draftName, colorId: colorId, items: [], icon: icon))
        }
        return WorkspaceTileIdentity.resolve(workspaces, hasIcon: hasIcon)[draftId] ?? .letter("?")
    }

    // MARK: Edits

    private func renameIfEditing() {
        guard let id = workspaceId, !trimmedName.isEmpty, workspace?.name != name else { return }
        model.renameWorkspace(id: id, newName: name)
    }

    func chooseColor(_ preset: WorkspaceColorId) {
        hasPendingCustomColor = false
        colorId = preset
        if let id = workspaceId, workspace?.colorId != preset {
            model.updateWorkspaceColor(id: id, colorId: preset)
        }
    }

    /// A tick of the color picker: previewed here, saved by `finish()` or `commit()`.
    func setCustomColor(_ color: UIColor) {
        let custom = WorkspaceColorId.custom(color.hexString)
        guard custom != colorId else { return }
        colorId = custom
        hasPendingCustomColor = true
    }

    /// Favicons or Letter, or Symbol with the last symbol picked.
    func chooseIcon(_ style: WorkspaceIcon) {
        switch style {
        case .symbol:
            if case .symbol = icon { return }
            apply(icon: .symbol(selectedSymbol))
        default:
            apply(icon: style)
        }
    }

    func chooseSymbol(_ symbol: String) {
        selectedSymbol = symbol
        apply(icon: .symbol(symbol))
    }

    private func apply(icon newIcon: WorkspaceIcon) {
        icon = newIcon
        if let id = workspaceId, workspace?.icon != newIcon {
            model.updateWorkspaceIcon(id: id, icon: newIcon)
        }
    }

    // MARK: Closing

    /// Creates the new workspace from the draft and opens it. Returns nil (and creates
    /// nothing) without a name, or once it has already been created.
    @discardableResult
    func commit() -> UUID? {
        guard canCommit else { return nil }
        isClosed = true
        let newId = model.createWorkspace(name: trimmedName, colorId: colorId)
        if icon != .favicons { model.updateWorkspaceIcon(id: newId, icon: icon) }
        createdId = newId
        return newId
    }

    /// Esc, Cancel or a swipe down on a new workspace: nothing is created.
    func cancel() {
        guard isNew else { return finish() }
        isClosed = true
    }

    /// The sheet is going away: an edited workspace keeps its last custom color.
    func finish() {
        guard !isClosed else { return }
        isClosed = true
        if let id = workspaceId, hasPendingCustomColor, workspace?.colorId != colorId {
            model.updateWorkspaceColor(id: id, colorId: colorId)
        }
        hasPendingCustomColor = false
    }

    /// Deletes the workspace at once, with an Undo toast.
    @discardableResult
    func delete(toasts: UndoToastCenter, undoManager: UndoManager?) -> Bool {
        guard let id = workspaceId, canDelete else { return false }
        isClosed = true
        return WorkspaceDeletion.delete(id, model: model, toasts: toasts, undoManager: undoManager)
    }

    func exportData() throws -> Data {
        guard let id = workspaceId else { throw CocoaError(.fileNoSuchFile) }
        return try model.exportWorkspace(id: id)
    }

    /// Goes to the workspace.
    func open() {
        finish()
        if let id = workspaceId { model.selectWorkspace(id: id) }
    }
}
