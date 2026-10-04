import AppKit

/// The due date flyout beside a task: a "Due date" header with the task's name, quick
/// picks (Today, Tomorrow, Next week), the calendar, then Clear, Cancel and Save. A quick
/// pick moves the calendar; Save (or Return) commits, Esc cancels, Clear removes the date.
@MainActor
final class DueDateFlyout: RailFlippedView {
    static let width: CGFloat = 270
    /// Days from today for each quick pick.
    static let quickDays = [0, 1, 7]

    private let titleLabel = FlyoutLabel.section("Due date")
    private let detailLabel: NSTextField
    let quickPicks: FlyoutSegmented
    let datePicker = NSDatePicker()
    private let line = NSView()
    let clearButton = FlyoutButton("Clear", style: .danger)
    let cancelButton = FlyoutButton("Cancel")
    let saveButton = FlyoutButton("Save ↩", style: .primary)

    private let initialDate: Date?
    private let onCommit: (Date?) -> Void
    /// Closes the flyout; the presenter sets it.
    var onClose: (() -> Void)?
    private let calendar = Calendar.current

    init(title: String?, dueDate: Date?, onCommit: @escaping (Date?) -> Void) {
        initialDate = dueDate
        self.onCommit = onCommit
        detailLabel = FlyoutLabel.text(title ?? "", size: 11, color: FlyoutColors.inkSecondary)
        quickPicks = FlyoutSegmented(["Today", "Tomorrow", "Next week"].map { .init(title: $0) },
                                     selected: -1, accessibilityLabel: "Quick picks")
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 280))
        detailLabel.alignment = .right
        quickPicks.onChange = { [weak self] index in self?.pickQuick(index) }

        datePicker.datePickerStyle = .clockAndCalendar
        datePicker.datePickerElements = .yearMonthDay
        datePicker.dateValue = dueDate ?? Date()
        datePicker.isBezeled = false
        datePicker.drawsBackground = false
        datePicker.target = self
        datePicker.action = #selector(calendarChanged)
        datePicker.sizeToFit()

        line.wantsLayer = true
        clearButton.isEnabled = dueDate != nil
        for (button, action) in [(clearButton, #selector(clearTapped)), (cancelButton, #selector(cancelTapped)),
                                 (saveButton, #selector(saveTapped))] {
            button.target = self
            button.action = action
        }
        for view in [titleLabel, detailLabel, quickPicks, datePicker, line, clearButton, cancelButton, saveButton] as [NSView] {
            addSubview(view)
        }
        syncQuickPicks()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Due date")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var calendarSize: NSSize {
        let fitting = datePicker.fittingSize
        return NSSize(width: max(fitting.width, 140), height: max(fitting.height, 148))
    }

    var preferredSize: NSSize {
        NSSize(width: Self.width, height: 12 + 16 + 8 + 24 + 10 + calendarSize.height + 10 + 1 + 10 + 24 + 12)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12, w = Self.width - pad * 2
        titleLabel.frame = NSRect(x: pad + 2, y: pad + 2, width: 80, height: 13)
        detailLabel.frame = NSRect(x: pad + 84, y: pad + 1, width: w - 86, height: 14)
        var y = pad + 16 + 8
        quickPicks.frame = NSRect(x: pad, y: y, width: w, height: 24)
        y += 24 + 10
        let cal = calendarSize
        datePicker.frame = NSRect(x: round((Self.width - cal.width) / 2), y: y, width: cal.width, height: cal.height)
        y += cal.height + 10
        line.frame = NSRect(x: pad, y: y, width: w, height: 1)
        line.layer?.backgroundColor = flyoutCG(FlyoutColors.line)
        y += 1 + 10
        let s = saveButton.fittingWidth, c = cancelButton.fittingWidth
        clearButton.frame = NSRect(x: pad, y: y, width: clearButton.fittingWidth, height: 24)
        saveButton.frame = NSRect(x: Self.width - pad - s, y: y, width: s, height: 24)
        cancelButton.frame = NSRect(x: saveButton.frame.minX - 6 - c, y: y, width: c, height: 24)
    }

    // MARK: Actions

    /// Moves the calendar to a quick pick; Save commits it.
    func pickQuick(_ index: Int) {
        guard Self.quickDays.indices.contains(index) else { return }
        let today = calendar.startOfDay(for: Date())
        datePicker.dateValue = calendar.date(byAdding: .day, value: Self.quickDays[index], to: today) ?? today
        if quickPicks.selectedIndex != index { quickPicks.selectedIndex = index }
    }

    @objc private func calendarChanged() { syncQuickPicks() }

    /// Lights the quick pick that matches the calendar, if any.
    private func syncQuickPicks() {
        let today = calendar.startOfDay(for: Date())
        let picked = calendar.startOfDay(for: datePicker.dateValue)
        let days = calendar.dateComponents([.day], from: today, to: picked).day
        quickPicks.selectedIndex = days.flatMap { Self.quickDays.firstIndex(of: $0) } ?? -1
    }

    func save() { commit(calendar.startOfDay(for: datePicker.dateValue)) }
    func cancel() { onClose?() }

    @objc private func saveTapped() { save() }
    @objc private func clearTapped() { commit(nil) }
    @objc private func cancelTapped() { cancel() }

    private func commit(_ date: Date?) {
        onCommit(date)
        onClose?()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: save()
        case 53: cancel()
        default: super.keyDown(with: event)
        }
    }

    /// Shows the due date flyout beside `anchor`. A click outside cancels.
    @discardableResult
    static func present(in flyouts: ItemFlyouts, title: String?, dueDate: Date?, from anchor: NSView,
                        onCommit: @escaping (Date?) -> Void) -> DueDateFlyout? {
        let editor = DueDateFlyout(title: title, dueDate: dueDate, onCommit: onCommit)
        editor.onClose = { [weak flyouts] in flyouts?.close(.dueDate) }
        let size = editor.preferredSize
        editor.frame.size = size
        guard flyouts.show(.dueDate, content: editor, size: size, from: anchor,
                           onEscape: { [weak editor] in editor?.cancel() },
                           onOutsideClick: { [weak editor] in editor?.cancel() }) else { return nil }
        editor.window?.makeFirstResponder(editor)
        return editor
    }
}
