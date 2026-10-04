import AppKit

/// Names, icons and the menu for "Opens in": "Browser I'm using", then each installed
/// browser with its profiles indented beneath it, so a browser and a profile are always
/// picked together.
@MainActor
enum OpensInMenu {
    struct Display: Equatable {
        var title: String
        var icon: NSImage?
    }

    static func browserName(_ bundleId: String) -> String {
        let name = BrowserManager.installedBrowsers().first { $0.bundleId == bundleId }?.name ?? bundleId
        return OpensIn.shortName(name)
    }

    static func profileName(_ choice: OpensIn) -> String? {
        guard let dir = choice.profile else { return nil }
        return BrowserManager.profiles(for: choice.bundleId).first { $0.directoryName == dir }?.displayName ?? dir
    }

    /// "Chrome · Work" with Chrome's icon, or "Browser I'm using" for no choice.
    static func display(_ choice: OpensIn?) -> Display {
        guard let choice else { return Display(title: OpensIn.browserImUsing, icon: nil) }
        let icon = BrowserManager.installedBrowsers().first { $0.bundleId == choice.bundleId }?.icon
        return Display(title: OpensIn.label(browserName: browserName(choice.bundleId), profileName: profileName(choice)), icon: icon)
    }

    /// The browser "Browser I'm using" would pick right now ("Arc now").
    static func currentBrowserName() -> String? {
        LinkTarget.forWorkspace(nil, searchEveryBrowser: false).bundleId.map(browserName)
    }

    /// Wraps an optional choice for representedObject (nil is "Browser I'm using").
    final class OpensInBox: NSObject {
        let choice: OpensIn?
        init(_ choice: OpensIn?) { self.choice = choice }
    }

    /// Fills `menu` with the choices. `includeBrowserImUsing` is off for a link's one-off
    /// Open in ▸. `current` gets the checkmark.
    static func populate(_ menu: NSMenu, current: OpensIn?, includeBrowserImUsing: Bool = true,
                         onPick: @escaping (OpensIn?) -> Void) {
        let target = MenuTarget(onPick: onPick)
        menu.autoenablesItems = false
        objc_setAssociatedObject(menu, &MenuTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        if includeBrowserImUsing {
            let item = NSMenuItem(title: OpensIn.browserImUsing, action: #selector(MenuTarget.picked(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = OpensInBox(nil)
            item.state = current == nil ? .on : .off
            if let now = currentBrowserName() { item.toolTip = "Follows whichever browser was last in front (\(now) now)" }
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for browser in BrowserManager.installedBrowsers() where browser.bundleId != Bundle.main.bundleIdentifier {
            let plain = OpensIn(bundleId: browser.bundleId, profile: nil)
            let item = NSMenuItem(title: OpensIn.shortName(browser.name), action: #selector(MenuTarget.picked(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = OpensInBox(plain)
            item.state = current == plain ? .on : .off
            if let icon = browser.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
            for profile in BrowserManager.profiles(for: browser.bundleId) {
                let choice = OpensIn(bundleId: browser.bundleId, profile: profile.directoryName)
                let sub = NSMenuItem(title: profile.displayName, action: #selector(MenuTarget.picked(_:)), keyEquivalent: "")
                sub.target = target
                sub.representedObject = OpensInBox(choice)
                sub.indentationLevel = 2
                sub.state = current == choice ? .on : .off
                sub.setAccessibilityLabel("\(OpensIn.shortName(browser.name)), \(profile.displayName) profile")
                menu.addItem(sub)
            }
        }
    }

    static func make(current: OpensIn?, includeBrowserImUsing: Bool = true, onPick: @escaping (OpensIn?) -> Void) -> NSMenu {
        let menu = NSMenu()
        populate(menu, current: current, includeBrowserImUsing: includeBrowserImUsing, onPick: onPick)
        return menu
    }
}

/// Retained by its menu; runs the pick with the item's choice.
final class MenuTarget: NSObject {
    nonisolated(unsafe) static var key = 0
    let onPick: (OpensIn?) -> Void
    init(onPick: @escaping (OpensIn?) -> Void) { self.onPick = onPick }
    @MainActor @objc func picked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? OpensInMenu.OpensInBox else { return }
        onPick(box.choice)
    }
}
