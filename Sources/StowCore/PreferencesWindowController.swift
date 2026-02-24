//
//  PreferencesWindowController.swift
//  Arcmark
//

import AppKit

final class PreferencesWindowController: NSWindowController {
    init() {
        let viewController = PreferencesViewController()
        let window = NSWindow(contentViewController: viewController)
        window.title = "Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 360, height: 450))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
