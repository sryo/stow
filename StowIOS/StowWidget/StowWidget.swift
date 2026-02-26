import WidgetKit
import SwiftUI
import StowShared

struct StowWidgetEntry: TimelineEntry {
    let date: Date
    let links: [StowShared.Link]
    let workspaceName: String
}

struct StowWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> StowWidgetEntry {
        StowWidgetEntry(date: Date(), links: [], workspaceName: "Stow")
    }

    func getSnapshot(in context: Context, completion: @escaping (StowWidgetEntry) -> Void) {
        let entry = loadEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StowWidgetEntry>) -> Void) {
        let entry = loadEntry()
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600)))
        completion(timeline)
    }

    private func loadEntry() -> StowWidgetEntry {
        let baseDir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.stow.app"
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stow")

        let store = DataStore(baseDirectory: baseDir)
        let state = store.load()

        let selectedId = state.selectedWorkspaceId
        let workspace = state.workspaces.first(where: { $0.id == selectedId }) ?? state.workspaces.first

        let links = collectLinks(from: workspace?.items ?? [])

        return StowWidgetEntry(
            date: Date(),
            links: links,
            workspaceName: workspace?.name ?? "Stow"
        )
    }

    private func collectLinks(from nodes: [Node]) -> [StowShared.Link] {
        var result: [StowShared.Link] = []
        for node in nodes {
            switch node {
            case .link(let link):
                result.append(link)
            case .folder(let folder):
                result.append(contentsOf: collectLinks(from: folder.children))
            case .task, .snippet:
                continue
            }
        }
        return result
    }
}

struct StowWidgetEntryView: View {
    var entry: StowWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.workspaceName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if entry.links.isEmpty {
                Text("No links")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                let maxLinks = family == .systemSmall ? 4 : 8
                let links = Array(entry.links.prefix(maxLinks))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: family == .systemSmall ? 2 : 4), spacing: 6) {
                    ForEach(links) { link in
                        if let url = URL(string: link.url) {
                            SwiftUI.Link(destination: url) {
                                VStack(spacing: 2) {
                                    Image(systemName: "globe")
                                        .font(.title3)
                                    Text(link.title)
                                        .font(.system(size: 9))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }
}

@main
struct StowWidget: Widget {
    let kind = "StowWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StowWidgetProvider()) { entry in
            StowWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Links")
        .description("Quick access to your workspace bookmarks.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
