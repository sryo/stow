import AppKit

final class NodeCollectionViewItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("NodeCollectionViewItem")
    private let rowView = NodeRowView()

    override func loadView() {
        view = rowView
    }

    func configure(title: String,
                   icon: NSImage?,
                   titleFont: NSFont,
                   depth: Int,
                   metrics: ListMetrics,
                   showDelete: Bool,
                   onDelete: (() -> Void)?,
                   isSelected: Bool,
                   isCompleted: Bool = false,
                   dueDate: Date? = nil,
                   subtitle: String? = nil) {
        view.alphaValue = 1
        view.layer?.transform = CATransform3DIdentity
        rowView.setIndentation(depth: depth, metrics: metrics)
        rowView.configure(
            title: title,
            icon: icon,
            titleFont: titleFont,
            showDelete: showDelete,
            metrics: metrics,
            onDelete: onDelete,
            isSelected: isSelected,
            isCompleted: isCompleted,
            dueDate: dueDate,
            subtitle: subtitle
        )
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
