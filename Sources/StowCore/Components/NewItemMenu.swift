import AppKit

/// What a "New…" menu's items call.
@MainActor
@objc protocol NewItemMenuTarget: AnyObject {
    func newFolderFromMenu(_ sender: Any?)
    func newTaskFromMenu(_ sender: Any?)
    func newSnippetFromMenu(_ sender: Any?)
    func newWorkspaceFromMenu(_ sender: Any?)
    @objc optional func pasteFromMenu(_ sender: Any?)
    @objc optional func importFromArcFromMenu(_ sender: Any?)
}

/// The one "New…" menu, for the title-bar +, the empty state's Add and the list's
/// background: sentence case like the flyouts, a symbol on every entry, and the menu
/// bar's keys (⌘⇧N folder, ⌘N workspace).
@MainActor
enum NewItemMenu {
    static func make(includePaste: Bool, includeImport: Bool, target: NewItemMenuTarget, pasteEnabled: Bool = true) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ symbol: String, _ action: Selector, key: String = "", mask: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = target
            menu.addItem(item)
            return item
        }
        if includePaste {
            add("Paste", "doc.on.clipboard", #selector(NewItemMenuTarget.pasteFromMenu(_:)), key: "v", mask: .command)
                .isEnabled = pasteEnabled
        }
        if includeImport {
            add("Import from Arc…", "square.and.arrow.down", #selector(NewItemMenuTarget.importFromArcFromMenu(_:)))
        }
        if includePaste || includeImport { menu.addItem(.separator()) }
        add("New folder…", "folder", #selector(NewItemMenuTarget.newFolderFromMenu(_:)), key: "N", mask: [.command, .shift])
        add("New task…", "circle", #selector(NewItemMenuTarget.newTaskFromMenu(_:)))
        add("New snippet…", "chevron.left.forwardslash.chevron.right", #selector(NewItemMenuTarget.newSnippetFromMenu(_:)))
        menu.addItem(.separator())
        add("New workspace…", "square.stack", #selector(NewItemMenuTarget.newWorkspaceFromMenu(_:)), key: "n", mask: .command)
        return menu
    }
}
