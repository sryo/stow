import AppKit

/// The menu actions AppDelegate answers. Items go up the responder chain (target nil),
/// which ends at the app delegate.
@MainActor @objc protocol AppMenuActions {
    func openPreferences(_ sender: Any?)
    func newWorkspace(_ sender: Any?)
    func newFolder(_ sender: Any?)
    func showImport(_ sender: Any?)
    func exportAll(_ sender: Any?)
    func showDataInFinder(_ sender: Any?)
    func restoreFromBackup(_ sender: Any?)
    func focusSearch(_ sender: Any?)
    func toggleJumpMode(_ sender: Any?)
    func showMainWindow(_ sender: Any?)
    func setWindowModeFromMenu(_ sender: NSMenuItem)
    func toggleAlwaysOnTop(_ sender: Any?)
    func toggleTabline(_ sender: Any?)
    func nextWorkspace(_ sender: Any?)
    func previousWorkspace(_ sender: Any?)
    func switchToWorkspaceByTag(_ sender: NSMenuItem)
}

@MainActor
enum AppMenus {
    /// The main menu. `target` is nil in the app (responder chain) and in tests.
    static func build(target: AnyObject?) -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
            return item
        }
        func submenu(_ title: String) -> NSMenu {
            let holder = NSMenuItem()
            main.addItem(holder)
            let menu = NSMenu(title: title)
            holder.submenu = menu
            return menu
        }

        let app = submenu("Stow")
        app.addItem(item("Settings…", #selector(AppMenuActions.openPreferences(_:)), ","))
        app.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Stow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.addItem(quit)

        let file = submenu("File")
        file.addItem(item("New Workspace…", #selector(AppMenuActions.newWorkspace(_:)), "n"))
        file.addItem(item("New Folder…", #selector(AppMenuActions.newFolder(_:)), "N", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Import…", #selector(AppMenuActions.showImport(_:)), "i", [.command, .shift]))
        file.addItem(item("Export All…", #selector(AppMenuActions.exportAll(_:)), "e", [.command, .shift]))
        let showData = item("Show Data in Finder", #selector(AppMenuActions.showDataInFinder(_:)), "e", [.command, .shift, .option])
        showData.isAlternate = true
        file.addItem(showData)
        file.addItem(item("Restore from Backup…", #selector(AppMenuActions.restoreFromBackup(_:))))

        let edit = submenu("Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(.separator())
        edit.addItem(item("Find…", #selector(AppMenuActions.focusSearch(_:)), "f"))
        edit.addItem(item("Jump to Item", #selector(AppMenuActions.toggleJumpMode(_:)), "j"))

        let window = submenu("Window")
        window.addItem(item("Show Stow", #selector(AppMenuActions.showMainWindow(_:)), "", []))
        let modeItem = NSMenuItem(title: "Window Mode", action: nil, keyEquivalent: "")
        let mode = NSMenu(title: "Window Mode")
        for (index, title) in ["Floating", "On Top", "Attached"].enumerated() {
            let choice = item(title, #selector(AppMenuActions.setWindowModeFromMenu(_:)), "", [])
            choice.tag = index
            mode.addItem(choice)
        }
        mode.addItem(.separator())
        mode.addItem(item("Switch On Top and Floating", #selector(AppMenuActions.toggleAlwaysOnTop(_:)), "t", [.command, .option]))
        modeItem.submenu = mode
        window.addItem(modeItem)
        window.addItem(item("Show Tabline", #selector(AppMenuActions.toggleTabline(_:)), "l", [.command, .option]))
        window.addItem(.separator())
        window.addItem(item("Next Workspace", #selector(AppMenuActions.nextWorkspace(_:)), "\t", [.control]))
        window.addItem(item("Previous Workspace", #selector(AppMenuActions.previousWorkspace(_:)), "\t", [.control, .shift]))
        for i in 1...9 {
            let ws = item("Workspace \(i)", #selector(AppMenuActions.switchToWorkspaceByTag(_:)), "\(i)")
            ws.tag = i
            window.addItem(ws)
        }
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        return main
    }

    /// Next/Previous Workspace: wraps around; from Settings (no current) it starts at the first.
    static func steppedIndex(current: Int?, count: Int, step: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return step >= 0 ? 0 : count - 1 }
        return ((current + step) % count + count) % count
    }
}

/// The ⌘1–9 workspace shortcuts as the menu bar shows them, read from the Window menu so
/// tips and VoiceOver can't drift from the real binding.
@MainActor
enum WorkspaceShortcut {
    private static let builtMenu = AppMenus.build(target: nil)

    /// "⌘1" for the first workspace; nil past the ninth, which has no shortcut.
    static func label(position: Int) -> String? {
        guard (1...9).contains(position) else { return nil }
        let menus = [NSApp?.mainMenu, builtMenu].compactMap { $0 }
        for menu in menus {
            if let item = find(position, in: menu), !item.keyEquivalent.isEmpty {
                return AllShortcuts.display(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
            }
        }
        return nil
    }

    private static func find(_ position: Int, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if let submenu = item.submenu, let hit = find(position, in: submenu) { return hit }
            if item.action == #selector(AppMenuActions.switchToWorkspaceByTag(_:)), item.tag == position { return item }
        }
        return nil
    }
}
