import SwiftUI
import StowShared

struct WorkspacePageView: View {
    @EnvironmentObject var viewModel: AppViewModel
    @State private var scrollOffset: CGFloat = 0
    @State private var showingEmptyClipboard = false

    var body: some View {
        let _ = viewModel.refreshTrigger
        let workspaces = viewModel.workspaces

        WorkspacePagerRepresentable(
            workspaces: workspaces,
            viewModel: viewModel,
            selectedWorkspaceId: Binding(
                get: { viewModel.selectedWorkspaceId },
                set: { if let id = $0 { viewModel.selectWorkspace(id: id) } }
            ),
            scrollOffset: $scrollOffset,
            onAddNewTriggered: {
                let id = viewModel.model.createWorkspace(name: "Untitled", colorId: .randomColor())
                viewModel.selectedWorkspaceId = id
            }
        )
        .background(interpolatedBackground(workspaces: workspaces).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pasteFromClipboard()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Nothing to paste", isPresented: $showingEmptyClipboard) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Copy a URL, task, or text to your clipboard first.")
        }
    }

    // MARK: - Paste from Clipboard

    private func pasteFromClipboard() {
        guard let pasted = UIPasteboard.general.string,
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showingEmptyClipboard = true
            return
        }
        let lines = pasted.components(separatedBy: .newlines)

        let taskPattern = try! NSRegularExpression(pattern: #"^\s*-?\s*\[([ xX]?)\]\s*(.+)"#)
        let urlPattern = #"(?i)\b(?:https?://[^\s<>"',;]+|localhost(?::\d+)?(?:/[^\s<>"',;]*)?)"#
        let urlRegex = try! NSRegularExpression(pattern: urlPattern)
        var snippetLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // 1. Check for task pattern: - [ ] or - [x]
            let range = NSRange(line.startIndex..., in: line)
            if let match = taskPattern.firstMatch(in: line, range: range),
               let checkRange = Range(match.range(at: 1), in: line),
               let textRange = Range(match.range(at: 2), in: line) {
                let checkMark = String(line[checkRange])
                let taskTitle = String(line[textRange]).trimmingCharacters(in: .whitespaces)
                let isCompleted = checkMark.lowercased() == "x"
                let taskId = viewModel.model.addTask(title: taskTitle, parentId: nil)
                if isCompleted {
                    viewModel.model.toggleTaskCompletion(id: taskId)
                }
                continue
            }

            // 2. Check for URLs
            let urls = extractUrls(from: trimmed, regex: urlRegex)
            if !urls.isEmpty {
                for url in urls {
                    let title = url.host ?? url.absoluteString
                    let linkId = viewModel.model.addLink(urlString: url.absoluteString, title: title, parentId: nil)
                    fetchTitleForNewLink(id: linkId, url: url)
                }
                continue
            }

            // 3. Accumulate as snippet text
            snippetLines.append(line)
        }

        // Create snippet from accumulated non-URL, non-task lines
        if !snippetLines.isEmpty {
            let content = snippetLines.joined(separator: "\n")
            let firstLine = snippetLines.first ?? "Snippet"
            let title = firstLine.count > 50 ? String(firstLine.prefix(50)) + "…" : firstLine
            viewModel.model.addSnippet(title: title, content: content, language: nil, parentId: nil)
        }
    }

    private func extractUrls(from text: String, regex: NSRegularExpression) -> [URL] {
        let range = NSRange(text.startIndex..., in: text)
        var urls: [URL] = []

        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range,
                  let stringRange = Range(matchRange, in: text) else { return }
            var candidate = String(text[stringRange])
            // Strip trailing punctuation
            while let last = candidate.last, ".,;:)]}?!".contains(last) {
                candidate.removeLast()
            }
            if let url = URL(string: candidate) {
                urls.append(url)
            }
        }

        return urls
    }

    private func fetchTitleForNewLink(id: UUID, url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        LinkTitleService.shared.fetchTitle(for: url, linkId: id) { title in
            guard let title else { return }
            _ = viewModel.model.updateLinkTitleIfDefault(id: id, newTitle: title)
        }
    }

    // MARK: - Background Color Interpolation

    private func interpolatedBackground(workspaces: [Workspace]) -> Color {
        guard !workspaces.isEmpty else { return .clear }

        let rawPage = scrollOffset
        let fromIndex = max(0, min(workspaces.count - 1, Int(floor(rawPage))))
        let toIndex = max(0, min(workspaces.count, Int(floor(rawPage)) + 1))

        if toIndex < workspaces.count {
            let fraction = rawPage - floor(rawPage)
            let fromColor = workspaces[fromIndex].colorId.backgroundColor
            let toColor = workspaces[toIndex].colorId.backgroundColor
            if let blended = fromColor.blended(withFraction: fraction, of: toColor) {
                return Color(uiColor: blended)
            }
            return Color(uiColor: fromColor)
        }

        if let last = workspaces.last {
            return Color(uiColor: last.colorId.backgroundColor)
        }
        return .clear
    }
}
