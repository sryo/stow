import XCTest
import UIKit
import StowShared
@testable import StowIOS

/// The one Edit Workspace sheet: the Mac editor's fields, edits that land on the
/// workspace, and a new workspace that exists only once it's created.
@MainActor
final class WorkspaceEditorTests: XCTestCase {
    private var testStore: TestStore!
    private var model: AppModel!

    override func setUp() async throws {
        testStore = TestStore(workspaces: ["Work", "Home", "Reading"], selected: 0)
        model = AppModel(store: testStore.store)
    }

    override func tearDown() async throws {
        testStore.remove()
    }

    private func editor(_ index: Int) -> WorkspaceEditorModel {
        WorkspaceEditorModel(editing: model.workspaces[index].id, in: model, hasIcon: { _ in false })
    }

    private func creator() -> WorkspaceEditorModel {
        WorkspaceEditorModel(creatingIn: model, hasIcon: { _ in false })
    }

    // MARK: Fields

    func testEditingStartsFromTheWorkspace() {
        model.updateWorkspaceIcon(id: model.workspaces[1].id, icon: .symbol("book"))
        let sheet = editor(1)
        XCTAssertFalse(sheet.isNew)
        XCTAssertEqual(sheet.title, "Edit Workspace")
        XCTAssertEqual(sheet.name, "Home")
        XCTAssertEqual(sheet.colorId, model.workspaces[1].colorId)
        XCTAssertEqual(sheet.icon, .symbol("book"))
        XCTAssertFalse(sheet.focusesName)
    }

    func testTheSheetOffersTheMacsColorsAndIcons() {
        XCTAssertEqual(WorkspaceEditorModel.presetColors, WorkspaceColorId.allCases)
        XCTAssertEqual(WorkspaceEditorModel.presetColors.map(\.name),
                       ["Blush", "Apricot", "Butter", "Leaf", "Mint", "Sky", "Periwinkle", "Lavender"])
        XCTAssertEqual(WorkspaceEditorModel.iconChoices.map(\.title), ["Favicons", "Letter", "Symbol"])
        XCTAssertEqual(WorkspaceEditorModel.symbols, WorkspaceTileIdentity.symbols)
    }

    func testRenamingLandsOnTheWorkspace() {
        let sheet = editor(1)
        sheet.name = "House"
        XCTAssertEqual(model.workspaces[1].name, "House")
    }

    func testAnEmptyNameIsNeverSaved() {
        let sheet = editor(1)
        sheet.name = "   "
        XCTAssertEqual(model.workspaces[1].name, "Home")
        sheet.finish()
        XCTAssertEqual(model.workspaces[1].name, "Home")
    }

    func testAPresetColorLandsAtOnce() {
        let sheet = editor(0)
        sheet.chooseColor(.graphite)
        XCTAssertEqual(sheet.colorId, .graphite)
        XCTAssertEqual(model.workspaces[0].colorId, .graphite)
    }

    func testACustomColorPreviewsThenCommitsOnce() {
        let sheet = editor(0)
        let before = model.workspaces[0].colorId
        sheet.setCustomColor(UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        sheet.setCustomColor(UIColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        XCTAssertEqual(sheet.colorId, .custom("#007FFF"))
        XCTAssertTrue(sheet.isCustomColor)
        XCTAssertEqual(model.workspaces[0].colorId, before, "the color panel's ticks only preview")
        sheet.finish()
        XCTAssertEqual(model.workspaces[0].colorId, .custom("#007FFF"))
    }

    func testChoosingAPresetDropsAPendingCustomColor() {
        let sheet = editor(0)
        sheet.setCustomColor(.red)
        sheet.chooseColor(.moss)
        sheet.finish()
        XCTAssertEqual(model.workspaces[0].colorId, .moss)
        XCTAssertFalse(sheet.isCustomColor)
    }

    func testIconChoicesLandAtOnce() {
        let sheet = editor(0)
        sheet.chooseIcon(.letter)
        XCTAssertEqual(model.workspaces[0].icon, .letter)
        sheet.chooseIcon(.symbol("star"))
        XCTAssertEqual(model.workspaces[0].icon, .symbol("star"))
        sheet.chooseSymbol("book")
        XCTAssertEqual(model.workspaces[0].icon, .symbol("book"))
        XCTAssertEqual(sheet.selectedSymbol, "book")
    }

    func testChoosingSymbolAgainKeepsTheSymbolPicked() {
        let sheet = editor(0)
        sheet.chooseSymbol("cart")
        sheet.chooseIcon(.symbol("star"))
        XCTAssertEqual(sheet.icon, .symbol("cart"))
        sheet.chooseIcon(.letter)
        sheet.chooseIcon(.symbol("star"))
        XCTAssertEqual(sheet.icon, .symbol("cart"), "Symbol comes back to the last symbol picked")
    }

    func testThePreviewFollowsTheDraft() {
        let sheet = editor(1)
        sheet.chooseIcon(.letter)
        XCTAssertEqual(sheet.preview, .letter("H"))
        sheet.chooseSymbol("flask")
        XCTAssertEqual(sheet.preview, .symbol("flask"))
        XCTAssertEqual(sheet.symbolPreview, .symbol("flask"))
        XCTAssertEqual(sheet.letterPreview, .letter("H"))
    }

    func testTheOnlyWorkspaceCantBeDeleted() {
        XCTAssertTrue(editor(0).canDelete)
        let single = TestStore(workspaces: ["Solo"])
        defer { single.remove() }
        let soloModel = AppModel(store: single.store)
        XCTAssertFalse(WorkspaceEditorModel(editing: soloModel.workspaces[0].id, in: soloModel).canDelete)
    }

    // MARK: New workspace

    func testANewWorkspaceStartsEmptyAndFocused() {
        let sheet = creator()
        XCTAssertTrue(sheet.isNew)
        XCTAssertEqual(sheet.title, "New Workspace")
        XCTAssertEqual(sheet.name, "")
        XCTAssertTrue(sheet.focusesName)
        XCTAssertFalse(sheet.canCommit, "an empty name can't create")
        XCTAssertFalse(sheet.canDelete)
    }

    func testANewWorkspaceIsOnlyCreatedOnCommit() {
        let sheet = creator()
        sheet.name = "Travel"
        sheet.chooseColor(.moss)
        sheet.chooseSymbol("paperplane")
        XCTAssertEqual(model.workspaces.count, 3, "typing and choosing create nothing")

        let id = sheet.commit()
        XCTAssertEqual(model.workspaces.count, 4)
        let created = model.workspaces.last!
        XCTAssertEqual(created.id, id)
        XCTAssertEqual(created.name, "Travel")
        XCTAssertEqual(created.colorId, .moss)
        XCTAssertEqual(created.icon, .symbol("paperplane"))
        XCTAssertEqual(model.state.selectedWorkspaceId, id, "the new workspace opens")
    }

    func testANewWorkspaceTakesACustomColor() {
        let sheet = creator()
        sheet.name = "Travel"
        sheet.setCustomColor(UIColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        sheet.commit()
        XCTAssertEqual(model.workspaces.last?.colorId, .custom("#007FFF"))
    }

    func testCommittingTrimsTheName() {
        let sheet = creator()
        sheet.name = "  Travel  "
        sheet.commit()
        XCTAssertEqual(model.workspaces.last?.name, "Travel")
    }

    func testCancelCreatesNothing() {
        let sheet = creator()
        sheet.name = "Travel"
        sheet.cancel()
        sheet.finish()
        XCTAssertEqual(model.workspaces.map(\.name), ["Work", "Home", "Reading"])
    }

    func testAnEmptyNameCreatesNothing() {
        let sheet = creator()
        sheet.name = "  "
        XCTAssertNil(sheet.commit())
        XCTAssertEqual(model.workspaces.count, 3)
    }

    func testCommitIsOnce() {
        let sheet = creator()
        sheet.name = "Travel"
        sheet.commit()
        sheet.commit()
        sheet.finish()
        XCTAssertEqual(model.workspaces.count, 4)
    }

    func testANewWorkspaceGetsADistinctColorByDefault() {
        let sheet = creator()
        XCTAssertFalse(model.workspaces.map(\.colorId).contains(sheet.colorId))
    }
}

/// Deleting a workspace goes at once, with an Undo toast, like the Mac's WorkspaceDeletion.
@MainActor
final class WorkspaceDeletionTests: XCTestCase {
    private var testStore: TestStore!
    private var model: AppModel!
    private var toasts: UndoToastCenter!

    override func setUp() async throws {
        testStore = TestStore(workspaces: ["Work", "Home", "Reading"], selected: 1)
        model = AppModel(store: testStore.store)
        toasts = UndoToastCenter()
    }

    override func tearDown() async throws {
        testStore.remove()
    }

    func testDeleteGoesAtOnceAndOffersUndo() {
        let home = model.workspaces[1]
        model.addFolder(name: "Kitchen", parentId: nil)
        XCTAssertTrue(WorkspaceDeletion.delete(home.id, model: model, toasts: toasts, undoManager: nil))
        XCTAssertEqual(model.workspaces.map(\.name), ["Work", "Reading"])
        XCTAssertEqual(toasts.current?.message, "Deleted “Home”")
    }

    func testUndoPutsItBackWhereItWas() {
        model.selectWorkspace(id: model.workspaces[1].id)
        model.addFolder(name: "Kitchen", parentId: nil)
        let home = model.workspaces[1]
        WorkspaceDeletion.delete(home.id, model: model, toasts: toasts, undoManager: nil)
        toasts.undo()
        XCTAssertEqual(model.workspaces.map(\.name), ["Work", "Home", "Reading"])
        XCTAssertEqual(model.workspaces[1], home, "its items come back too")
        XCTAssertNil(toasts.current)
    }

    func testTheUndoWindowCloses() {
        let home = model.workspaces[1]
        WorkspaceDeletion.delete(home.id, model: model, toasts: toasts, undoManager: nil)
        toasts.expire()
        XCTAssertNil(toasts.current)
        toasts.undo()
        XCTAssertFalse(model.workspaces.contains { $0.id == home.id })
    }

    func testANewToastClosesTheLastOne() {
        WorkspaceDeletion.delete(model.workspaces[1].id, model: model, toasts: toasts, undoManager: nil)
        WorkspaceDeletion.delete(model.workspaces[1].id, model: model, toasts: toasts, undoManager: nil)
        XCTAssertEqual(toasts.current?.message, "Deleted “Reading”")
        toasts.undo()
        XCTAssertEqual(model.workspaces.map(\.name), ["Work", "Reading"])
    }

    func testShakeUndoesToo() {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        WorkspaceDeletion.delete(model.workspaces[1].id, model: model, toasts: toasts, undoManager: undoManager)
        undoManager.endUndoGrouping()
        undoManager.undo()
        XCTAssertEqual(model.workspaces.map(\.name), ["Work", "Home", "Reading"])
        XCTAssertNil(toasts.current)
    }

    func testTheOnlyWorkspaceStays() {
        let single = TestStore(workspaces: ["Solo"])
        defer { single.remove() }
        let soloModel = AppModel(store: single.store)
        XCTAssertFalse(WorkspaceDeletion.delete(soloModel.workspaces[0].id, model: soloModel, toasts: toasts, undoManager: nil))
        XCTAssertEqual(soloModel.workspaces.count, 1)
        XCTAssertNil(toasts.current)
    }

    func testDeletingFromTheEditorUsesTheSameUndo() {
        let sheet = WorkspaceEditorModel(editing: model.workspaces[2].id, in: model)
        XCTAssertTrue(sheet.delete(toasts: toasts, undoManager: nil))
        XCTAssertEqual(model.workspaces.count, 2)
        toasts.undo()
        XCTAssertEqual(model.workspaces.map(\.name), ["Work", "Home", "Reading"])
    }
}

/// Over-swiping past the last workspace asks for a new one through the editor; landing
/// there never creates a workspace by itself.
final class PagerLandingTests: XCTestCase {
    func testLandingOnAWorkspacePageSelectsIt() {
        XCTAssertEqual(WorkspacePagerViewController.landing(onPage: 0, pageCount: 4), .workspace(0))
        XCTAssertEqual(WorkspacePagerViewController.landing(onPage: 2, pageCount: 4), .workspace(2))
    }

    func testLandingPastTheLastWorkspaceAsksForANewOne() {
        XCTAssertEqual(WorkspacePagerViewController.landing(onPage: 3, pageCount: 4), .newWorkspace)
    }

    @MainActor
    func testTheOverSwipeOpensTheEditorWithoutCreating() {
        let testStore = TestStore(workspaces: ["Work", "Home"])
        defer { testStore.remove() }
        let model = AppModel(store: testStore.store)
        let request = WorkspaceEditorModel.forOverSwipe(in: model)
        XCTAssertTrue(request.isNew)
        XCTAssertTrue(request.focusesName)
        XCTAssertEqual(request.name, "")
        XCTAssertEqual(model.workspaces.count, 2, "swiping past the last page creates nothing by itself")
        request.cancel()
        request.finish()
        XCTAssertEqual(model.workspaces.count, 2)
    }
}
