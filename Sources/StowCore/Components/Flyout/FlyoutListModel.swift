import Foundation
import StowShared

/// One row of a FlyoutListView: glyph · title · trailing, with an open dot or a check.
struct FlyoutListRow: Equatable {
    enum Glyph: Equatable {
        /// The site's favicon or its SiteGlyph letter tile.
        case site(title: String, url: String, faviconPath: String?)
        case folder
        case task(done: Bool)
        case snippet
        case workspace(WorkspaceColorId)
        case symbol(String)
    }

    enum Action: Equatable {
        case openLink(UUID)
        case pushFolder(UUID)
        case toggleTask(UUID)
        case copySnippet(UUID)
        case newTask
        case selectWorkspace(UUID)
        case setDueDate(UUID)
        case editSnippet(UUID)
    }

    var id: String
    var glyph: Glyph
    var title: String
    /// Quiet text at the end: a count, a due date, a language, a shortcut.
    var trailing: String?
    /// Shown in place of `trailing` while the row is hovered or selected ("Edit", "Due…").
    var hoverTrailing: String?
    /// What clicking the trailing text does, when it's a button of its own.
    var secondary: Action?
    var isOverdue = false
    /// A ● for a link whose exact page is open in a browser.
    var isOpen = false
    /// A done task, the current workspace, a snippet just copied.
    var isChecked = false
    /// Picking the row leaves the flyout open (tasks toggle, snippets copy, folders push).
    var keepsOpen = false
    /// The item behind the row, for right-click and dragging out.
    var node: Node?
    var action: Action
}

/// A titled run of rows; a flyout shows one or more (the Tabline pocket: tasks, then snippets).
struct FlyoutListSection: Equatable {
    var title: String?
    var rows: [FlyoutListRow]
}

/// Builds flyout rows from the model, the same way for the rail and the Tabline.
enum FlyoutListModel {
    /// A folder's live links and subfolders. Its tasks and snippets live in the pocket.
    static func rows(for folder: Folder, openKeys: Set<String>) -> [FlyoutListRow] {
        rows(for: folder.children, openKeys: openKeys)
    }

    /// Links and folders from a list of nodes (a folder's children, the Tabline's
    /// overflow). Folders push a chained flyout.
    static func rows(for nodes: [Node], openKeys: Set<String>) -> [FlyoutListRow] {
        nodes.unarchived().compactMap { node in
            switch node {
            case .link(let link):
                return FlyoutListRow(
                    id: link.id.uuidString,
                    glyph: .site(title: link.title, url: link.url, faviconPath: link.faviconPath),
                    title: link.title.isEmpty ? (link.displayDomain ?? link.url) : link.title,
                    isOpen: URLCanonical.key(link.url).map(openKeys.contains) ?? false,
                    node: node,
                    action: .openLink(link.id))
            case .folder(let folder):
                return FlyoutListRow(
                    id: folder.id.uuidString,
                    glyph: .folder,
                    title: folder.name,
                    trailing: "\(rows(for: folder.children, openKeys: []).count) ›",
                    keepsOpen: true,
                    node: node,
                    action: .pushFolder(folder.id))
            case .task, .snippet:
                return nil
            }
        }
    }

    static let newTaskRowId = "new-task"

    /// Tasks toggle in place and show their due dates; the rail ends with "New task".
    static func rows(for tasks: [TaskItem], newTask: Bool = true, now: Date = Date(),
                     calendar: Calendar = .current) -> [FlyoutListRow] {
        let today = calendar.startOfDay(for: now)
        var rows = tasks.filter { !$0.isArchived }.map { task -> FlyoutListRow in
            var due: String?
            var overdue = false
            if task.isCompleted {
                due = "done"
            } else if let date = task.dueDate {
                due = dueFormatter(calendar).string(from: date)
                if date < today {
                    overdue = true
                    due = "! " + (due ?? "")
                }
            }
            return FlyoutListRow(
                id: task.id.uuidString,
                glyph: .task(done: task.isCompleted),
                title: task.title,
                trailing: due,
                hoverTrailing: task.isCompleted ? nil : (task.dueDate == nil ? "Due…" : nil),
                secondary: task.isCompleted ? nil : .setDueDate(task.id),
                isOverdue: overdue,
                isChecked: task.isCompleted,
                keepsOpen: true,
                node: .task(task),
                action: .toggleTask(task.id))
        }
        if newTask {
            rows.append(FlyoutListRow(id: newTaskRowId, glyph: .symbol("plus"), title: "New task", action: .newTask))
        }
        return rows
    }

    /// Snippets copy on a click, then show a check; the trailing "Edit" opens the editor.
    static func rows(for snippets: [Snippet]) -> [FlyoutListRow] {
        snippets.filter { !$0.isArchived }.map { snippet in
            FlyoutListRow(
                id: snippet.id.uuidString,
                glyph: .snippet,
                title: snippet.title,
                trailing: snippet.language.flatMap { $0.isEmpty ? nil : $0 },
                hoverTrailing: "Edit",
                secondary: .editSnippet(snippet.id),
                keepsOpen: true,
                node: .snippet(snippet),
                action: .copySnippet(snippet.id))
        }
    }

    /// A workspace switcher: the colored dot, the ⌘-number shortcut, a check on the current one.
    static func rows(forWorkspaces workspaces: [(id: UUID, name: String, colorId: WorkspaceColorId)], current: UUID?,
                     shortcut: (Int) -> String?) -> [FlyoutListRow] {
        workspaces.enumerated().map { i, ws in
            FlyoutListRow(
                id: ws.id.uuidString,
                glyph: .workspace(ws.colorId),
                title: ws.name,
                trailing: shortcut(i + 1),
                isChecked: ws.id == current,
                action: .selectWorkspace(ws.id))
        }
    }

    private static func dueFormatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }
}
