import Foundation

/// Brings Stow's window back after Toggle Stow or when the Tabline gives way to it.
@MainActor
struct WindowRevealer {
    var isAttached: () -> Bool
    var orderFront: () -> Void
    var makeKeyAndActivate: () -> Void
    var placeOnBrowser: () -> Void

    func reveal() {
        if isAttached() {
            placeOnBrowser()
            orderFront()
        } else {
            makeKeyAndActivate()
        }
    }
}
