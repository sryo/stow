import AppKit
import StowCore

@MainActor
@main
struct StowApp {
    private static var appDelegate: AppDelegate?

    static func main() {
        autoreleasepool {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            appDelegate = delegate
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            app.run()
        }
    }
}
