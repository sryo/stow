import AppKit
import StowShared

/// Shared construction for context-menu pieces that appear in more than one
/// controller. Hosts keep their own selectors; the builder only assembles the
/// items and visuals so the two menus can't drift apart.
@MainActor
enum ContextMenuBuilder {

    /// The "Change Color" submenu: one checkable item per workspace color with
    /// a swatch image, then a separator and a "Custom Color…" item.
    static func workspaceColorSubmenu(
        currentColorId: WorkspaceColorId,
        target: AnyObject,
        colorAction: Selector,
        customColorAction: Selector
    ) -> NSMenu {
        let submenu = NSMenu()
        for colorId in WorkspaceColorId.allCases {
            let item = NSMenuItem(title: colorId.name, action: colorAction, keyEquivalent: "")
            item.target = target
            item.representedObject = colorId
            item.image = colorPreviewImage(color: colorId.color)
            if colorId == currentColorId {
                item.state = .on
            }
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom Color…", action: customColorAction, keyEquivalent: "")
        customItem.target = target
        submenu.addItem(customItem)
        return submenu
    }

    static func colorPreviewImage(color: NSColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let path = NSBezierPath(ovalIn: rect)
        color.setFill()
        path.fill()

        let borderColor = NSColor(calibratedRed: 0.078, green: 0.078, blue: 0.078, alpha: 0.20)
        borderColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        image.unlockFocus()
        return image
    }
}
