import WidgetKit
import SwiftUI
import StowShared

struct StowWidgetEntry: TimelineEntry {
    let date: Date
    let links: [StowShared.Link]
    let workspaceName: String
}

/// Each widget shows the workspace picked in Edit Widget; unconfigured widgets follow the
/// workspace open in the app.
struct StowWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> StowWidgetEntry {
        StowWidgetEntry(date: Date(), links: [], workspaceName: "Stow")
    }

    func snapshot(for configuration: SelectWorkspaceIntent, in context: Context) async -> StowWidgetEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectWorkspaceIntent, in context: Context) async -> Timeline<StowWidgetEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .after(Date().addingTimeInterval(3600)))
    }

    private func entry(for configuration: SelectWorkspaceIntent) -> StowWidgetEntry {
        let content = WidgetContent.make(choice: configuration.workspace?.choice, state: AppGroup.makeStore().load())
        return StowWidgetEntry(date: Date(), links: content.links, workspaceName: content.workspaceName)
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
struct StowWidgetBundle: WidgetBundle {
    var body: some Widget {
        StowWidget()
        StowLiveActivity()
    }
}

struct StowWidget: Widget {
    let kind = "StowWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectWorkspaceIntent.self, provider: StowWidgetProvider()) { entry in
            StowWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Links")
        .description("Links from a workspace. Long-press and choose Edit Widget to pick which one.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
