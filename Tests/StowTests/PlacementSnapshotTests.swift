import XCTest
import ServiceManagement
@testable import StowCore

@MainActor
private final class SnapshotLoginItem: LoginItemControlling {
    var status: SMAppService.Status = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

/// Renders every "Where Stow lives" state on screen and captures it, for comparing with
/// the design. Runs only with STOW_SNAPSHOT_DIR set; it needs a display and screen capture.
@MainActor
final class PlacementSnapshotTests: XCTestCase {
    private struct State {
        var name: String
        var rows: Bool
        var mode: AppWindowMode
        var edge: BrowserDock = .left
        var hasAccessibility = true
        var browserInFront = true
        var hover: AppWindowMode?
        var edgeHover: BrowserDock?
        var focusCards = false
        var focusEdges = false
    }

    private static let states: [State] = [
        State(name: "float", rows: false, mode: .floating),
        State(name: "top", rows: false, mode: .onTop),
        State(name: "float-hover-top", rows: false, mode: .floating, hover: .onTop),
        State(name: "float-focus", rows: false, mode: .floating, focusCards: true),
        State(name: "attach-left", rows: false, mode: .attached, edge: .left),
        State(name: "attach-right", rows: false, mode: .attached, edge: .right),
        State(name: "attach-top", rows: false, mode: .attached, edge: .top),
        State(name: "attach-bottom", rows: false, mode: .attached, edge: .bottom),
        State(name: "attach-left-ehover-bottom", rows: false, mode: .attached, edge: .left, edgeHover: .bottom),
        State(name: "attach-left-efocus", rows: false, mode: .attached, edge: .left, focusEdges: true),
        State(name: "attach-left-noax", rows: false, mode: .attached, edge: .left, hasAccessibility: false),
        State(name: "attach-top-noax", rows: false, mode: .attached, edge: .top, hasAccessibility: false),
        State(name: "float-noax-hover-attach", rows: false, mode: .floating, hasAccessibility: false, hover: .attached),
        State(name: "attach-right-nobrowser", rows: false, mode: .attached, edge: .right, browserInFront: false),
        State(name: "page-float", rows: true, mode: .floating),
        State(name: "page-top", rows: true, mode: .onTop),
        State(name: "page-hover-attach", rows: true, mode: .floating, hover: .attached),
        State(name: "page-focus", rows: true, mode: .onTop, focusCards: true),
        State(name: "page-attach-top", rows: true, mode: .attached, edge: .top),
        State(name: "page-attach-left", rows: true, mode: .attached, edge: .left),
        State(name: "page-attach-left-noax", rows: true, mode: .attached, edge: .left, hasAccessibility: false),
        State(name: "page-attach-top-nobrowser", rows: true, mode: .attached, edge: .top, browserInFront: false),
    ]

    func testCaptureEveryState() throws {
        guard let dir = ProcessInfo.processInfo.environment["STOW_SNAPSHOT_DIR"] else {
            throw XCTSkip("set STOW_SNAPSHOT_DIR to capture the placement states")
        }
        let saved = FocusRing.focusCameFromKeyboard
        defer { FocusRing.focusCameFromKeyboard = saved }
        for dark in [false, true] {
            for state in Self.states {
                try capture(state, dark: dark, to: "\(dir)/\(state.name)-\(dark ? "dk" : "lt").png")
            }
        }
    }

    private func capture(_ state: State, dark: Bool, to path: String) throws {
        let width: CGFloat = state.rows ? 308 : 252
        let margin: CGFloat = 12
        let picker = WindowPlacementPicker()
        picker.surface = state.rows ? .page : .flyout
        picker.reduceMotion = { true }
        picker.placement = WindowPlacement(dock: state.mode == .attached ? state.edge : .none,
                                           keepsOnTop: state.mode == .onTop, lastEdge: state.edge)
        picker.hasAccessibility = state.hasAccessibility
        picker.browserInFront = state.browserInFront
        picker.frame = NSRect(x: margin, y: margin, width: width, height: 100)
        picker.layoutSubtreeIfNeeded()
        if let hover = state.hover { picker.hover(hover) }
        if let edge = state.edgeHover { picker.edgePicker.hoveredEdge = edge }
        let height = picker.height(forWidth: width)
        picker.frame.size.height = height

        let size = NSSize(width: width + margin * 2, height: height + margin * 2)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 500, y: 150), size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let content = FlippedSnapshotView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        window.contentView = content
        content.addSubview(picker)
        window.backgroundColor = state.rows ? SettingsColors.surface : PlacementColors.background(.flyout)
        // A window hands focus to its first key view as it opens: that shows no ring.
        FocusRing.focusCameFromKeyboard = { false }
        window.orderFrontRegardless()
        // Tabbing in does.
        FocusRing.focusCameFromKeyboard = { true }
        if state.focusCards || state.focusEdges { window.makeFirstResponder(nil) }
        if state.focusCards { window.makeFirstResponder(picker) }
        if state.focusEdges { window.makeFirstResponder(picker.edgePicker) }
        content.layoutSubtreeIfNeeded()
        content.display()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try task.run()
        task.waitUntilExit()
        window.orderOut(nil)
    }
}

private final class FlippedSnapshotView: NSView {
    override var isFlipped: Bool { true }
}
