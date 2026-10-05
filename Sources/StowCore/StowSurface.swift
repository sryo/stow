import Foundation

/// Stow is on screen as one thing at a time: its window, or the Tabline riding the
/// browser. While the Tabline runs the window stays away, and Toggle Stow and reopening
/// act on the Tabline instead.
@MainActor
final class StowSurface {
    private let showWindow: () -> Void
    private let hideWindow: () -> Void
    private let setTablineHidden: (Bool) -> Void

    private(set) var tablineRunning = false
    /// Put away with Toggle Stow; whichever surface is current stays away until the next one.
    private(set) var isUserHidden = false

    init(showWindow: @escaping () -> Void, hideWindow: @escaping () -> Void,
         setTablineHidden: @escaping (Bool) -> Void) {
        self.showWindow = showWindow
        self.hideWindow = hideWindow
        self.setTablineHidden = setTablineHidden
    }

    func tablineRunningChanged(_ running: Bool) {
        guard running != tablineRunning else { return }
        tablineRunning = running
        if running {
            hideWindow()
            setTablineHidden(isUserHidden)
        } else {
            setTablineHidden(false)
            if !isUserHidden { showWindow() }
        }
    }

    func toggle() {
        isUserHidden.toggle()
        if tablineRunning {
            setTablineHidden(isUserHidden)
        } else if isUserHidden {
            hideWindow()
        } else {
            showWindow()
        }
    }

    /// The Dock icon clicked, or the app opened again.
    func reopen() {
        isUserHidden = false
        if tablineRunning { setTablineHidden(false) } else { showWindow() }
    }
}
