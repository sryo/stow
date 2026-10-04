import AppKit

/// The main window's own keys, ahead of the responder chain: ⌘ held alone reveals jump
/// letters (⌘ + letter opens that row), ⌘J's jump mode takes plain letters, "/" focuses
/// search, and Esc leaves jump mode, clears search or steps back out of Settings.
@MainActor
final class KeyboardRouter {
    private unowned let main: MainViewController
    private var model: AppModel { main.model }
    private var list: NodeListViewController { main.nodeListViewController }

    nonisolated(unsafe) private var keyEventMonitor: Any?
    nonisolated(unsafe) private var flagsMonitor: Any?
    /// Pending reveal of jump letters while ⌘ is held on its own.
    private var commandHoldReveal: DispatchWorkItem?
    /// True while the letters are showing because ⌘ is held (as opposed to ⌘J mode).
    private var isCommandHoldJump = false

    init(main: MainViewController) {
        self.main = main
    }

    deinit {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Installs the key and modifier monitors.
    func start() {
        // Plain a-z key monitor for item activation
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handleCommandHoldKey(event) { return nil }
            if self.handlePlainKeyEvent(event) { return nil }
            return event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    /// Handles plain a-z key presses for item activation.
    /// Returns true if the event was consumed.
    /// Holding ⌘ alone reveals the a–z jump letters after a short pause, so quick ⌘
    /// shortcuts never flash them. Releasing ⌘ hides them again.
    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags == .command {
            // Modifier events often arrive without a window, so check key status instead.
            guard commandHoldReveal == nil, !isCommandHoldJump, main.acceptsListShortcuts,
                  main.view.window?.isKeyWindow == true,
                  !model.state.isSettingsSelected, !main.isSwiping,
                  !(main.view.window?.firstResponder is NSTextView),
                  list.hasNodeRows,
                  !list.isJumpModeActive else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.commandHoldReveal = nil
                self.isCommandHoldJump = true
                self.list.jumpLetters = Self.commandSafeLetters
                self.list.isJumpModeActive = true
                self.setShortcutHintsVisible(true)
            }
            commandHoldReveal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        } else {
            endCommandHold()
        }
    }

    func endCommandHold() {
        commandHoldReveal?.cancel()
        commandHoldReveal = nil
        if isCommandHoldJump {
            isCommandHoldJump = false
            list.isJumpModeActive = false
            list.jumpLetters = Array("abcdefghijklmnopqrstuvwxyz")
            setShortcutHintsVisible(false)
        }
    }

    /// Letters free of ⌘ shortcuts (⌘A C F H J M N Q T V W X Z and system ones are taken),
    /// so ⌘ + letter can open a row without stealing a command.
    private static let commandSafeLetters: [Character] = Array("bdegiklopsruy")

    /// Shows keycaps on every control that has a shortcut while ⌘ is held.
    private func setShortcutHintsVisible(_ visible: Bool) {
        main.pasteButton.keycapText = visible ? "⌘V" : nil
        main.workspaceSwitcher.showsShortcutHints = visible
        main.searchField.showsShortcutHint = visible
    }

    /// ⌘ + letter while the hold hints are showing opens that row. Any key pressed
    /// before the hints appear is a normal shortcut and cancels the reveal.
    private func handleCommandHoldKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        guard isCommandHoldJump else {
            commandHoldReveal?.cancel()
            commandHoldReveal = nil
            return false
        }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
              let letter = chars.first, let index = list.rowIndex(forJumpLetter: letter) else {
            // Not a row letter: let the menu shortcut (⌘V, ⌘F, ⌘1…) run as usual.
            endCommandHold()
            return false
        }
        endCommandHold()
        activateRow(at: index)
        return true
    }

    private func activateRow(at index: Int) {
        guard let node = list.visibleNode(at: index) else { return }
        switch node {
        case .link(let link):
            main.links.openLink(link)
        case .folder(let folder):
            if !main.searchCoordinator.isSearchActive {
                model.setFolderExpanded(id: folder.id, isExpanded: !folder.isExpanded)
            }
        case .task(let task):
            model.toggleTaskCompletion(id: task.id)
        case .snippet(let snippet):
            main.copySnippetToClipboard(snippet.id)
        }
    }

    private func handlePlainKeyEvent(_ event: NSEvent) -> Bool {
        let window = main.view.window
        guard event.window === window, window?.isKeyWindow == true else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isEmpty || flags == .capsLock || flags == .shift else { return false }
        if event.keyCode == 53, main.elasticMode == .rail, model.state.isSettingsSelected, !main.isSwiping,
           !(window?.firstResponder is NSTextView) {
            return main.rail.settingsRail.handleEscape()
        }
        guard !model.state.isSettingsSelected, !main.isSwiping else { return false }
        let isEditingText = window?.firstResponder is NSTextView

        // Esc leaves jump mode, or clears an active search and returns to the list.
        if event.keyCode == 53 {
            if list.isJumpModeActive {
                list.isJumpModeActive = false
                return true
            }
            if main.searchCoordinator.isSearchActive || isEditingText && main.searchField.isFocused {
                main.clearSearch()
                return true
            }
            return false
        }

        if isEditingText { return false }

        guard let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let scalar = chars.unicodeScalars.first else { return false }

        if chars == "/" && flags.isEmpty && main.acceptsListShortcuts {
            main.focusSearch()
            return true
        }

        // Letters activate rows only in jump mode, so a stray keystroke can't open a link.
        guard list.isJumpModeActive, flags.isEmpty || flags == .capsLock,
              scalar.value >= 97 && scalar.value <= 122 else { return false }

        list.isJumpModeActive = false
        if let index = list.rowIndex(forJumpLetter: Character(chars)) {
            activateRow(at: index)
        }
        return true
    }

    /// ⌘J: letters on the rows, until a letter or Esc.
    func toggleJumpMode() {
        guard !model.state.isSettingsSelected else { return }
        guard main.acceptsListShortcuts, list.hasNodeRows else {
            NSSound.beep()
            return
        }
        list.isJumpModeActive.toggle()
    }
}
