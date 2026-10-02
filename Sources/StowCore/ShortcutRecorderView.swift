import AppKit
import Carbon

/// An interactive view for recording keyboard shortcuts.
/// Displays the current shortcut and allows the user to record a new one or clear it.
@MainActor
final class ShortcutRecorderView: NSView {
    var onShortcutChanged: ((KeyboardShortcut?) -> Void)?

    private var currentShortcut: KeyboardShortcut?
    private var isRecording = false
    private var monitor: Any?

    // Style constants matching SettingsButton / browser popup
    private var baseBackgroundColor: NSColor { SettingsColors.fill }
    private var recordingBackgroundColor: NSColor { SettingsColors.fillStrong }
    private var textColor: NSColor { SettingsColors.ink }
    private var placeholderColor: NSColor { SettingsColors.inkSecondary }
    private let cornerRadius: CGFloat = 8

    // UI elements
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let recordButton = ShortcutActionButton(title: "Record")
    private let clearButton = ShortcutActionButton(title: "Clear")

    init() {
        super.init(frame: .zero)
        setupUI()
        loadCurrentShortcut()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = resolvedCGColor(baseBackgroundColor)
        layer?.cornerRadius = cornerRadius

        // Shortcut display label
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        shortcutLabel.textColor = textColor
        shortcutLabel.alignment = .left

        // Record button
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)

        // Clear button
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)

        addSubview(shortcutLabel)
        addSubview(recordButton)
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),

            shortcutLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            recordButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            recordButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func loadCurrentShortcut() {
        currentShortcut = KeyboardShortcut.load()
        updateDisplay()
    }

    private func updateDisplay() {
        if isRecording {
            shortcutLabel.stringValue = "Press shortcut…"
            shortcutLabel.textColor = placeholderColor
            recordButton.title = "Cancel"
            layer?.backgroundColor = resolvedCGColor(recordingBackgroundColor)
            clearButton.isHidden = true
        } else if let shortcut = currentShortcut {
            shortcutLabel.stringValue = shortcut.displayString
            shortcutLabel.textColor = textColor
            recordButton.title = "Record"
            layer?.backgroundColor = resolvedCGColor(baseBackgroundColor)
            clearButton.isHidden = false
        } else {
            shortcutLabel.stringValue = "None"
            shortcutLabel.textColor = placeholderColor
            recordButton.title = "Record"
            layer?.backgroundColor = resolvedCGColor(baseBackgroundColor)
            clearButton.isHidden = true
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        updateDisplay()

        // Temporarily unregister the global hotkey so it doesn't fire while recording
        GlobalHotkeyService.shared.unregister()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        updateDisplay()

        // Re-register the current shortcut
        if let shortcut = currentShortcut {
            GlobalHotkeyService.shared.register(shortcut: shortcut)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // Escape cancels recording
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        guard let shortcut = KeyboardShortcut(event: event) else {
            return
        }

        currentShortcut = shortcut
        shortcut.save()
        stopRecording()
        onShortcutChanged?(shortcut)
    }

    @objc private func clearShortcut() {
        currentShortcut = nil
        KeyboardShortcut.clear()
        GlobalHotkeyService.shared.unregister()
        updateDisplay()
        onShortcutChanged?(nil)
    }
}

// MARK: - Shortcut Action Button

/// A small text button used within the ShortcutRecorderView.
private final class ShortcutActionButton: NSButton {
    private var trackingArea: NSTrackingArea?

    private var normalColor: NSColor { SettingsColors.inkSecondary }
    private var hoverColor: NSColor { SettingsColors.ink }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        font = NSFont.systemFont(ofSize: 11, weight: .medium)
        contentTintColor = normalColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        contentTintColor = hoverColor
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        contentTintColor = normalColor
    }
}
