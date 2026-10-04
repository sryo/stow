import Foundation

/// A workspace's one or two letters, for the strip's chips, letter tiles, the Settings
/// rows and the iPhone's Live Activity. Letters are unique among the workspaces passed
/// together: a first letter, then a second where first letters collide ("Work" and
/// "Writing" read "Wo" and "Wr").
public enum WorkspaceMonogram {
    /// One or two letters per workspace, keyed by id, unique where first letters collide.
    public static func assign(_ workspaces: [(id: UUID, name: String)]) -> [UUID: String] {
        func letters(_ s: String) -> [Character] {
            Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        func first(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        }
        let names = workspaces.map(\.name)
        var result = names.map(first)
        let groups = Dictionary(grouping: names.indices, by: { result[$0] })
        for (_, group) in groups where group.count > 1 {
            for i in group {
                let words = names[i].split(separator: " ")
                if words.count > 1 {
                    result[i] = first(String(words[0])) + first(String(words[1]))
                } else {
                    let l = letters(names[i])
                    result[i] = first(names[i]) + (l.count > 1 ? String(l[1]) : "")
                }
            }
            for i in group where group.contains(where: { $0 != i && result[$0] == result[i] }) {
                let l = letters(names[i])
                for k in 1..<max(l.count, 1) {
                    let candidate = first(names[i]) + String(l[k])
                    if !group.contains(where: { $0 != i && result[$0] == candidate }) {
                        result[i] = candidate
                        break
                    }
                }
            }
        }
        var byId: [UUID: String] = [:]
        for (i, workspace) in workspaces.enumerated() { byId[workspace.id] = result[i] }
        return byId
    }

    /// The letters of a workspace on its own, with nothing to collide with.
    public static func resolve(name: String) -> String {
        resolve(UUID(), name: name)
    }

    /// The letters of one workspace among `others` (which may include it).
    public static func resolve(_ id: UUID, name: String, among others: [(id: UUID, name: String)] = []) -> String {
        var all = others.filter { $0.id != id }
        all.append((id, name))
        return assign(all)[id] ?? "?"
    }
}
