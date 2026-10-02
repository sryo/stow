import AppKit

/// Due date editor shown in a popover anchored to the task row: quick picks
/// (Today, Tomorrow, Next week), a calendar, and Clear / Save.
final class DueDatePopoverController: NSViewController {
    private let datePicker = NSDatePicker()
    private let initialDate: Date?
    private let onCommit: (Date?) -> Void

    init(dueDate: Date?, onCommit: @escaping (Date?) -> Void) {
        self.initialDate = dueDate
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: "Due date")
        title.font = StowTheme.Font.title

        let quick = NSStackView(views: [
            quickButton("Today", days: 0),
            quickButton("Tomorrow", days: 1),
            quickButton("Next week", days: 7),
        ])
        quick.spacing = 6
        quick.distribution = .fillEqually

        datePicker.datePickerStyle = .clockAndCalendar
        datePicker.datePickerElements = .yearMonthDay
        datePicker.dateValue = initialDate ?? Date()
        datePicker.isBezeled = false
        datePicker.drawsBackground = false

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearTapped))
        clear.isEnabled = initialDate != nil
        let save = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [clear, NSView(), cancel, save])
        footer.spacing = 6

        let stack = NSStackView(views: [title, quick, datePicker, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            quick.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        view = root
    }

    private func quickButton(_ title: String, days: Int) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(quickPicked(_:)))
        button.tag = days
        button.controlSize = .small
        return button
    }

    @objc private func quickPicked(_ sender: NSButton) {
        let today = Calendar.current.startOfDay(for: Date())
        let date = Calendar.current.date(byAdding: .day, value: sender.tag, to: today) ?? today
        commit(date)
    }

    @objc private func saveTapped() { commit(Calendar.current.startOfDay(for: datePicker.dateValue)) }
    @objc private func clearTapped() { commit(nil) }
    @objc private func cancelTapped() { dismiss(nil) }

    private func commit(_ date: Date?) {
        onCommit(date)
        dismiss(nil)
    }
}
