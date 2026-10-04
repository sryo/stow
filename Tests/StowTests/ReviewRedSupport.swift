import AppKit
import XCTest
@testable import StowCore
import StowShared

/// Shared scaffolding for the review's red tests: a throwaway model and a
/// MainViewController hosted in a window at a given Elastic width.
@MainActor
final class RedHarness {
    let tempDir: URL
    let model: AppModel
    private(set) var controller: MainViewController!
    private(set) var window: NSWindow!

    init() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("stow-red-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        model = AppModel(store: DataStore(baseDirectory: tempDir))
        for item in model.currentWorkspace.items { model.deleteNodeFromAnyWorkspace(id: item.id) }
    }

    func host(width: CGFloat, height: CGFloat = 620) {
        controller = MainViewController(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        spin()
    }

    var nodeList: NodeListViewController {
        controller.children.compactMap { $0 as? NodeListViewController }.first!
    }

    func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func tearDown() {
        window?.orderOut(nil)
        window?.contentViewController = nil
        try? FileManager.default.removeItem(at: tempDir)
    }
}

extension NSView {
    /// Every descendant of a given type, depth first.
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        var found: [T] = []
        for view in subviews {
            if let match = view as? T { found.append(match) }
            found.append(contentsOf: view.descendants(of: type))
        }
        return found
    }
}
