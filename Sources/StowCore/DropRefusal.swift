import Foundation

/// Why the list won't take a dragged item where it hovers, said once per reason per drag
/// so the pointer can wander without repeating it.
struct DropRefusal {
    private let show: (String) -> Void
    private var shown: Set<String> = []

    init(show: @escaping (String) -> Void) { self.show = show }

    static func reason(searchActive: Bool, dragged: NodeSection, staysInSection: Bool) -> String? {
        if searchActive { return "Clear the search to rearrange" }
        guard !staysInSection else { return nil }
        switch dragged {
        case .tasks: return "Tasks stay with tasks"
        case .snippets: return "Snippets stay with snippets"
        case .links: return "Links and folders stay above tasks and snippets"
        }
    }

    mutating func note(_ reason: String?) {
        guard let reason, shown.insert(reason).inserted else { return }
        show(reason)
    }

    mutating func dragEnded() { shown.removeAll() }
}
