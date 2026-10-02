import AppKit

final class NodeCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NodeCollectionViewItem")
    private let rowView = NodeRowView()

    override func loadView() {
        view = rowView
    }

    func configure(content: NodeRowContent,
                   metrics: ListMetrics,
                   isSelected: Bool,
                   showSlotAction: Bool,
                   onSlotAction: (() -> Void)?) {
        view.alphaValue = 1
        view.layer?.transform = CATransform3DIdentity
        rowView.configure(
            content: content,
            metrics: metrics,
            isSelected: isSelected,
            showSlotAction: showSlotAction,
            onSlotAction: onSlotAction
        )
    }

    var onDisclosure: (() -> Void)? {
        get { rowView.onDisclosure }
        set { rowView.onDisclosure = newValue }
    }

    var onSwipeRight: (() -> Void)? {
        get { rowView.onSwipeRight }
        set { rowView.onSwipeRight = newValue }
    }

    var onSwipeLeft: (() -> Void)? {
        get { rowView.onSwipeLeft }
        set { rowView.onSwipeLeft = newValue }
    }

    var swipeEnabled: Bool {
        get { rowView.swipeEnabled }
        set { rowView.swipeEnabled = newValue }
    }

    func setSwipeRightIcon(_ symbolName: String, tintColor: NSColor) {
        rowView.setSwipeRightIcon(symbolName, tintColor: tintColor)
    }

    func setSwipeLeftIcon(_ symbolName: String, tintColor: NSColor) {
        rowView.setSwipeLeftIcon(symbolName, tintColor: tintColor)
    }

    func setKeyboardFocused(_ focused: Bool) {
        rowView.isKeyboardFocused = focused
    }

    func setHintCharacter(_ hint: String?) {
        rowView.setHintCharacter(hint)
    }

    func refreshHoverState() {
        rowView.refreshHoverState()
    }

    var isInlineRenaming: Bool {
        rowView.isInlineRenaming
    }

    func beginInlineRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        rowView.beginInlineRename(onCommit: onCommit, onCancel: onCancel)
    }

    func cancelInlineRename() {
        rowView.cancelInlineRename()
    }
}
