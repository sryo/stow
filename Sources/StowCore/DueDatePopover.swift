import AppKit

/// Due date editor shown in a popover anchored to the task row: quick picks
/// (Today, Tomorrow, Next week), a calendar, and Clear / Save.
final class DueDatePopoverController: NSViewController {
    private let datePicker = NSDatePicker()
    private let initialDate: Date?
    private let onCommit: (Date?) -> Void
    /// Closes the popover. The presenter sets it to the popover's `performClose`; by default
    /// it closes the NSPopover found up the responder chain (a popover is its content view
    /// controller's next responder). `dismiss(nil)` does nothing here, since the controller
    /// was never presented, only set as the popover's content.
    var close: (() -> Void)?

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
    @objc private func cancelTapped() { closePopover() }

    /// Esc cancels, wherever focus is in the popover.
    override func cancelOperation(_ sender: Any?) { closePopover() }

    private func commit(_ date: Date?) {
        onCommit(date)
        closePopover()
    }

    private func closePopover() {
        if let close { return close() }
        var responder = nextResponder
        while let current = responder {
            if let popover = current as? NSPopover { return popover.performClose(nil) }
            responder = current.nextResponder
        }
    }

    /// Opens toward whichever side of the row has more room in the window, so a row near
    /// the top doesn't put the popover above the window. In a flipped anchor `maxY` is
    /// the row's bottom edge.
    static func preferredEdge(rowInWindow row: NSRect, windowHeight: CGFloat, anchorIsFlipped: Bool) -> NSRectEdge {
        let roomBelow = row.minY
        let roomAbove = windowHeight - row.maxY
        let below: NSRectEdge = anchorIsFlipped ? .maxY : .minY
        let above: NSRectEdge = anchorIsFlipped ? .minY : .maxY
        return roomBelow >= roomAbove ? below : above
    }
}
