import AppKit
import Carbon

/// Records one global shortcut (Toggle Stow or Stow front tab), drawn like the app
/// sheet: keycap chips and a Record button. While recording, ⌫ clears the shortcut and
/// Esc cancels. Refusals and browser-conflict warnings are reported through
/// `onStatusChanged` so the sheet can show them under the group.
@MainActor
final class FlyoutShortcutRecorder: NSView {
    enum State: Equatable {
        case empty
        case set(KeyboardShortcut)
        case recording
        case rejected(attempt: [String])
    }

    enum StatusKind { case help, success, warning, danger }

    let action: HotkeyAction
    var store = ShortcutStore()
    /// Called with nil to clear the line.
    var onStatusChanged: ((String?, StatusKind) -> Void)?
    /// After a shortcut is saved or cleared.
    var onShortcutChanged: (() -> Void)?

    private(set) var state: State = .empty
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var rejectedWork: DispatchWorkItem?
    private var statusWork: DispatchWorkItem?

    private var keycaps: [FlyoutKeycap] = []
    private let noneLabel = FlyoutLabel.text("None", size: 11.5, color: FlyoutColors.inkSecondary)
    private let field = RecordingField()
    let recordButton = FlyoutButton("Record", height: 22, fontSize: 11.5)

    static let recordingHelp = "Press the new shortcut. ⌫ clears, Esc cancels."

    init(action: HotkeyAction) {
        self.action = action
        super.init(frame: .zero)
        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        recordButton.setAccessibilityLabel("Record \(action.title) shortcut")
        noneLabel.alignment = .right
        addSubview(noneLabel)
        addSubview(field)
        addSubview(recordButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(action.title)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    deinit {
        MainActor.assumeIsolated {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }
    }

    /// Re-reads the stored shortcut (it may have changed in the other Settings surface).
    func reload() {
        guard !isRecording else { return }
        state = store.shortcut(for: action).map { .set($0) } ?? .empty
        updateDisplay()
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelRecording()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelRecording() }
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

    static func spokenName(_ shortcut: KeyboardShortcut) -> String {
        let names: [String: String] = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command"]
        return keyParts(of: shortcut).map { names[$0] ?? $0 }.joined(separator: " ")
    }

    private func setKeycaps(_ parts: [String]) {
        keycaps.forEach { $0.removeFromSuperview() }
        keycaps = parts.map { FlyoutKeycap($0) }
        keycaps.forEach(addSubview)
    }

    private func updateDisplay() {
        switch state {
        case .empty:
            setKeycaps([])
            noneLabel.isHidden = false
            field.isHidden = true
            recordButton.title = "Record"
            setAccessibilityValue("None")
        case .set(let shortcut):
            setKeycaps(Self.keyParts(of: shortcut))
            noneLabel.isHidden = true
            field.isHidden = true
            recordButton.title = "Record"
            setAccessibilityValue(Self.spokenName(shortcut))
        case .recording:
            setKeycaps([])
            noneLabel.isHidden = true
            field.isHidden = false
            field.show(parts: nil, rejected: false)
            recordButton.title = "Cancel"
        case .rejected(let attempt):
            setKeycaps([])
            noneLabel.isHidden = true
            field.isHidden = false
            field.show(parts: attempt, rejected: true)
            recordButton.title = "Cancel"
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let b = recordButton.fittingWidth
        recordButton.frame = NSRect(x: bounds.width - b, y: (h - 22) / 2, width: b, height: 22)
        var x = recordButton.frame.minX - 8
        for cap in keycaps.reversed() {
            let w = cap.fittingWidth
            x -= w
            cap.frame = NSRect(x: x, y: (h - 20) / 2, width: w, height: 20)
            x -= 4
        }
        noneLabel.frame = NSRect(x: 0, y: (h - 14) / 2, width: recordButton.frame.minX - 8, height: 14)
        field.frame = NSRect(x: 0, y: (h - 22) / 2, width: recordButton.frame.minX - 6, height: 22)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func report(_ text: String?, _ kind: StatusKind, clearAfter seconds: TimeInterval? = nil) {
        statusWork?.cancel()
        onStatusChanged?(text, kind)
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.onStatusChanged?(nil, .help) }
        statusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Recording

    var isRecording: Bool {
        switch state {
        case .recording, .rejected: return true
        default: return false
        }
    }

    @objc private func toggleRecording() {
        if isRecording { cancelRecording() } else { startRecording() }
    }

    func startRecording() {
        state = .recording
        updateDisplay()
        report(Self.recordingHelp, .help)
        announce("Recording \(action.title). Press a shortcut. Delete clears, Escape cancels.")
        // A registered hotkey would fire instead of being recorded.
        GlobalHotkeyService.shared.unregisterAll()
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

    /// Ends recording without saving.
    func cancelRecording() {
        guard isRecording else { return }
        finishRecording()
        state = store.shortcut(for: action).map { .set($0) } ?? .empty
        updateDisplay()
        report(nil, .help)
    }

    private func finishRecording() {
        rejectedWork?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        GlobalHotkeyService.shared.apply(store)
    }

    /// Returns the event to let it through, or nil to consume it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseDown {
            let point = convert(event.locationInWindow, from: nil)
            if event.window !== window || !bounds.contains(point) { cancelRecording() }
            return event
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty {
            switch Int(event.keyCode) {
            case kVK_Escape:
                cancelRecording()
                return nil
            case kVK_Delete, kVK_ForwardDelete:
                clear()
                return nil
            case kVK_Tab:
                cancelRecording()
                return event
            default:
                break
            }
        }
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control),
              let shortcut = KeyboardShortcut(event: event) else {
            reject(attempt: [], reason: "Include ⌘, ⌥ or ⌃.")
            return nil
        }
        if let reason = ShortcutConflicts.systemRejection(for: shortcut)
            ?? ShortcutConflicts.stowRejection(for: shortcut, recording: action, store: store) {
            reject(attempt: Self.keyParts(of: shortcut), reason: "\(reason) Try another.")
            return nil
        }
        save(shortcut)
        return nil
    }

    private func reject(attempt: [String], reason: String) {
        state = .rejected(attempt: attempt)
        updateDisplay()
        report(reason, .danger)
        announce(reason)
        rejectedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .rejected = self.state else { return }
            self.state = .recording
            self.updateDisplay()
            self.report(Self.recordingHelp, .help)
        }
        rejectedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func save(_ shortcut: KeyboardShortcut) {
        store.set(shortcut, for: action)
        finishRecording()
        state = .set(shortcut)
        updateDisplay()
        onShortcutChanged?()
        NotificationCenter.default.post(name: .toggleSidebarShortcutChanged, object: nil)
        if let warning = ShortcutConflicts.browserWarning(for: shortcut) {
            // Kept, but the browser loses it while Stow runs.
            report("\(warning) Stow takes it while running.", .warning)
            announce(warning)
        } else if GlobalHotkeyService.shared.registeredShortcut(for: action) != shortcut {
            report("Another app already uses \(shortcut.displayString).", .danger)
        } else {
            report("Saved. Press \(Self.keyParts(of: shortcut).joined()) in any app.", .success, clearAfter: 2.5)
            announce("\(action.title) set to \(Self.spokenName(shortcut)).")
        }
    }

    /// Clears the shortcut: nothing is registered until a new one is recorded.
    func clear() {
        store.clear(action)
        finishRecording()
        state = .empty
        updateDisplay()
        onShortcutChanged?()
        NotificationCenter.default.post(name: .toggleSidebarShortcutChanged, object: nil)
        report("\(action.title) has no shortcut.", .help, clearAfter: 2.5)
        announce("\(action.title) shortcut cleared.")
    }
}

extension KeyboardShortcut: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(carbonModifiers)
    }
}

// MARK: - Keycap

/// A 20pt keycap chip: a hairline square with the key in 11pt medium.
final class FlyoutKeycap: NSView {
    private let label: NSTextField

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        label.font = FlyoutFonts.ui(11, .medium)
        label.alignment = .center
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var fittingWidth: CGFloat { max(20, ceil(label.intrinsicContentSize.width) + 8) }

    override func layout() {
        super.layout()
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = flyoutCG(FlyoutColors.line)
        layer?.backgroundColor = flyoutCG(FlyoutColors.background)
        label.textColor = FlyoutColors.ink
    }
}

/// The field shown while recording: "Type a shortcut", or the refused keys, outlined
/// in the accent color (danger while a shortcut is refused).
private final class RecordingField: NSView {
    private let placeholder = FlyoutLabel.text("Press keys", size: 11.5, color: FlyoutColors.inkSecondary)
    private var caps: [FlyoutKeycap] = []
    private var isRejected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addSubview(placeholder)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func show(parts: [String]?, rejected: Bool) {
        isRejected = rejected
        caps.forEach { $0.removeFromSuperview() }
        caps = (parts ?? []).map { FlyoutKeycap($0) }
        caps.forEach(addSubview)
        placeholder.isHidden = !caps.isEmpty
        setAccessibilityLabel(rejected ? "Shortcut refused" : "Type a shortcut")
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        placeholder.frame = NSRect(x: 7, y: (bounds.height - 14) / 2, width: bounds.width - 14, height: 14)
        var x: CGFloat = 2
        for cap in caps {
            let w = cap.fittingWidth
            cap.frame = NSRect(x: x, y: 1, width: w, height: bounds.height - 2)
            x += w + 3
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 2
        layer?.borderColor = flyoutCG(isRejected ? FlyoutColors.danger : FlyoutColors.recording)
        layer?.backgroundColor = flyoutCG(FlyoutColors.field)
    }
}
