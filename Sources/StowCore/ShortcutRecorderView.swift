import AppKit
import Carbon

/// Records the Toggle Stow shortcut.
///
/// States: empty ("None" + Record), set (keycap chips + Record + Clear), recording (an
/// accent-outlined field + Cancel), rejected (a danger-outlined field showing the keys
/// that were refused, for at least 2.5s) and saved (set, with a confirmation line).
/// Status lines are reported through `onStatusChanged` so the page can show them under
/// the row.
@MainActor
final class ShortcutRecorderView: NSView {
    enum State: Equatable {
        case empty
        case set(KeyboardShortcut)
        case recording
        case rejected(attempt: [String], reason: String)
    }

    var onShortcutChanged: ((KeyboardShortcut?) -> Void)?
    /// The help or status line for the current state, or nil for none.
    var onStatusChanged: ((String?, SettingsStatusLine.Kind) -> Void)?

    private(set) var state: State = .empty
    private var currentShortcut: KeyboardShortcut?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var rejectedWork: DispatchWorkItem?
    private var savedWork: DispatchWorkItem?

    private let stack = NSStackView()
    private let keycaps = NSStackView()
    private let noneLabel = SettingsLabel.meta("None")
    private let field = RecorderField()
    private let recordButton = SettingsButton(title: "Record", accessibilityLabel: "Record shortcut")
    private let clearButton = SettingsIconButton(symbolName: "xmark", accessibilityLabel: "Clear shortcut", pointSize: 9)

    /// Shortcuts Stow or macOS already use.
    static let conflicts: [KeyboardShortcut: String] = {
        let cmd = UInt32(cmdKey), ctrl = UInt32(controlKey)
        return [
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Comma), carbonModifiers: cmd): "⌘, opens Settings.",
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: cmd): "⌘Q quits apps.",
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_N), carbonModifiers: cmd): "⌘N makes new things.",
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_W), carbonModifiers: cmd): "⌘W closes windows.",
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_H), carbonModifiers: cmd): "⌘H hides apps.",
            KeyboardShortcut(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: cmd): "⌘M minimizes windows.",
            KeyboardShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: cmd): "⌘Space opens Spotlight.",
            KeyboardShortcut(keyCode: UInt32(kVK_Tab), carbonModifiers: cmd): "⌘Tab switches apps.",
            KeyboardShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: ctrl): "⌃Space switches input sources.",
        ]
    }()

    init() {
        super.init(frame: .zero)
        setupUI()
        currentShortcut = KeyboardShortcut.load()
        state = currentShortcut.map { .set($0) } ?? .empty
        updateDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        MainActor.assumeIsolated {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        keycaps.orientation = .horizontal
        keycaps.spacing = 3
        keycaps.setClippingResistancePriority(.defaultLow, for: .horizontal)
        keycaps.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keycaps.setAccessibilityElement(true)
        keycaps.setAccessibilityRole(.staticText)

        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let fieldWidth = field.widthAnchor.constraint(equalToConstant: 132)
        fieldWidth.priority = .defaultHigh
        fieldWidth.isActive = true

        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        clearButton.isBordered = true
        clearButton.target = self
        clearButton.action = #selector(clearShortcut)

        for view in [noneLabel, keycaps, field, recordButton, clearButton] as [NSView] {
            stack.addArrangedSubview(view)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsMetrics.controlHeight),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelRecording()
    }

    // MARK: Display

    static func keyParts(of shortcut: KeyboardShortcut) -> [String] {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var parts: [String] = []
        var rest = Substring(shortcut.displayString)
        while let first = rest.first, modifiers.contains(first) {
            parts.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    private static func spokenName(_ shortcut: KeyboardShortcut) -> String {
        let names: [String: String] = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command"]
        return keyParts(of: shortcut).map { names[$0] ?? $0 }.joined(separator: " ")
    }

    private func setKeycaps(_ parts: [String], in stack: NSStackView) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for part in parts {
            stack.addArrangedSubview(KeycapView(part))
        }
    }

    private func updateDisplay() {
        switch state {
        case .empty:
            noneLabel.isHidden = false
            keycaps.isHidden = true
            field.isHidden = true
            clearButton.isHidden = true
            recordButton.setTitle("Record")
            recordButton.setAccessibilityLabel("Record shortcut")
        case .set(let shortcut):
            noneLabel.isHidden = true
            keycaps.isHidden = false
            setKeycaps(Self.keyParts(of: shortcut), in: keycaps)
            keycaps.setAccessibilityLabel("Toggle Stow shortcut, \(Self.spokenName(shortcut))")
            field.isHidden = true
            clearButton.isHidden = false
            recordButton.setTitle("Record")
            recordButton.setAccessibilityLabel("Record shortcut")
        case .recording:
            noneLabel.isHidden = true
            keycaps.isHidden = true
            field.isHidden = false
            field.show(parts: nil, rejected: false)
            clearButton.isHidden = true
            recordButton.setTitle("Cancel")
            recordButton.setAccessibilityLabel("Cancel recording")
        case .rejected(let attempt, _):
            noneLabel.isHidden = true
            keycaps.isHidden = true
            field.isHidden = false
            field.show(parts: attempt, rejected: true)
            clearButton.isHidden = true
            recordButton.setTitle("Cancel")
        }
        invalidateIntrinsicContentSize()
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Recording

    var isRecording: Bool {
        switch state {
        case .recording, .rejected: return true
        default: return false
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            cancelRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        savedWork?.cancel()
        state = .recording
        updateDisplay()
        onStatusChanged?("Include ⌘, ⌥ or ⌃. Esc cancels.", .help)
        announce("Recording, press a shortcut. Escape cancels.")

        // The global hotkey would fire instead of being recorded.
        GlobalHotkeyService.shared.unregister()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
    }

    /// Ends recording without saving and re-registers the previous hotkey.
    func cancelRecording() {
        guard isRecording else { return }
        finishRecording()
        state = currentShortcut.map { .set($0) } ?? .empty
        updateDisplay()
        onStatusChanged?(nil, .help)
        NotificationCenter.default.post(name: .toggleSidebarShortcutChanged, object: nil)
    }

    private func finishRecording() {
        rejectedWork?.cancel()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let shortcut = currentShortcut {
            GlobalHotkeyService.shared.register(shortcut: shortcut)
        }
    }

    /// Returns the event to let it through, or nil to consume it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseDown {
            let point = convert(event.locationInWindow, from: nil)
            if event.window !== window || !bounds.contains(point) {
                cancelRecording()
            }
            return event
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == UInt16(kVK_Escape) && flags.isEmpty {
            cancelRecording()
            return nil
        }
        if event.keyCode == UInt16(kVK_Tab) && !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) {
            cancelRecording()
            return event
        }
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            reject(attempt: [], reason: "Include ⌘, ⌥ or ⌃.")
            return nil
        }
        guard let shortcut = KeyboardShortcut(event: event) else { return nil }
        if let reason = Self.conflicts[shortcut] {
            reject(attempt: Self.keyParts(of: shortcut), reason: "\(reason) Try another.")
            return nil
        }
        save(shortcut)
        return nil
    }

    private func reject(attempt: [String], reason: String) {
        state = .rejected(attempt: attempt, reason: reason)
        updateDisplay()
        onStatusChanged?(reason, .danger)
        announce(reason)
        rejectedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .rejected = self.state else { return }
            self.state = .recording
            self.updateDisplay()
            self.onStatusChanged?("Include ⌘, ⌥ or ⌃. Esc cancels.", .help)
        }
        rejectedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func save(_ shortcut: KeyboardShortcut) {
        currentShortcut = shortcut
        shortcut.save()
        finishRecording()
        state = .set(shortcut)
        updateDisplay()
        onShortcutChanged?(shortcut)
        let display = Self.keyParts(of: shortcut).joined()
        onStatusChanged?("Saved. Press \(display) anywhere.", .success)
        announce("Shortcut set to \(Self.spokenName(shortcut)).")
        savedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .set = self.state else { return }
            self.onStatusChanged?(nil, .help)
        }
        savedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    @objc private func clearShortcut() {
        currentShortcut = nil
        KeyboardShortcut.clear()
        GlobalHotkeyService.shared.unregister()
        state = .empty
        updateDisplay()
        onStatusChanged?(nil, .help)
        onShortcutChanged?(nil)
        announce("Shortcut cleared.")
    }
}

extension KeyboardShortcut: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(carbonModifiers)
    }
}

// MARK: - Keycap

/// An 18pt keycap chip in Font.keycap with a controlEdge outline.
private final class KeycapView: NSView {
    private let label: NSTextField

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = StowTheme.Font.keycap
        label.textColor = SettingsColors.ink
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = SettingsColors.edge.cgColor
        layer?.backgroundColor = SettingsColors.raised.cgColor
    }
}

// MARK: - Recording field

/// The field shown while recording: "Type a shortcut" (or the refused keys) and an esc
/// hint, outlined in accent, or in danger while a shortcut is refused.
private final class RecorderField: NSView {
    private let placeholder = SettingsLabel.meta("Type a shortcut")
    private let keys = NSStackView()
    private let escCap = KeycapView("esc")
    private var isRejected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        placeholder.font = StowTheme.Font.row
        keys.translatesAutoresizingMaskIntoConstraints = false
        keys.orientation = .horizontal
        keys.spacing = 3
        addSubview(placeholder)
        addSubview(keys)
        addSubview(escCap)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsMetrics.controlHeight),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: escCap.leadingAnchor, constant: -4),
            keys.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
            escCap.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            escCap.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(parts: [String]?, rejected: Bool) {
        isRejected = rejected
        keys.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let parts = parts ?? []
        for part in parts { keys.addArrangedSubview(KeycapView(part)) }
        placeholder.isHidden = !parts.isEmpty
        setAccessibilityLabel(rejected ? "Shortcut refused" : "Type a shortcut")
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = SettingsMetrics.rowRadius
        layer?.borderWidth = SettingsMetrics.focusRingWidth
        layer?.borderColor = (isRejected ? SettingsColors.danger : SettingsColors.accent).cgColor
        layer?.backgroundColor = SettingsColors.raised.cgColor
    }
}
