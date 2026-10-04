import Foundation

/// Where Stow sits on the browser window in front: the attached sidebar on its left or
/// right, the Tabline on its top or bottom edge, or nowhere. One dock at a time.
enum BrowserDock: String, CaseIterable {
    case none, left, right, top, bottom

    var isSidebar: Bool { self == .left || self == .right }
    var isTabline: Bool { tablineEdge != nil }

    var tablineEdge: TablineEdge? {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        default: return nil
        }
    }

    /// The `sidebarPosition` value the window attachment code reads.
    var sidebarPosition: String? {
        switch self {
        case .left: return "left"
        case .right: return "right"
        default: return nil
        }
    }

    /// From the settings before the dock existed: Attached on a side wins, then the Tabline
    /// switch (which only rode the top), then nothing.
    static func migrated(attached: Bool, position: String?, tabline: Bool) -> BrowserDock {
        if attached { return position == "left" ? .left : .right }
        return tabline ? .top : .none
    }
}

/// Which edge of the browser window the Tabline rides.
enum TablineEdge: String {
    case top, bottom

    init(stored: String?) {
        self = stored.flatMap(TablineEdge.init(rawValue:)) ?? .top
    }
}
