import ActivityKit
import SwiftUI
import WidgetKit
import StowShared

/// The current workspace in the Dynamic Island and on the Lock Screen.
struct StowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StowActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(context.state.colors.surface))
                .activitySystemActionForegroundColor(Color(context.state.colors.inkPrimary))
        } dynamicIsland: { context in
            let state = context.state
            let island = state.colors.dark
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MonogramDisc(state: state, size: 36)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(state.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(linkCountLabel(state.linkCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LinkRow(
                        links: state.links,
                        tileFill: Color(rgb: island.paper),
                        tileInk: Color(rgb: island.inkPrimary),
                        titleColor: .white.opacity(0.85)
                    )
                    .padding(.top, 6)
                }
            } compactLeading: {
                MonogramDisc(state: state, size: 22)
            } compactTrailing: {
                Text("\(state.linkCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(rgb: state.colors.light.surface))
                    .accessibilityLabel(linkCountLabel(state.linkCount))
            } minimal: {
                MonogramDisc(state: state, size: 22)
            }
            .keylineTint(Color(rgb: state.colors.light.surface))
        }
    }
}

private func linkCountLabel(_ count: Int) -> String {
    count == 1 ? "1 link" : "\(count) links"
}

private struct LockScreenView: View {
    let state: StowActivityAttributes.ContentState

    var body: some View {
        let colors = state.colors
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MonogramDisc(state: state, size: 28)
                Text(state.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(linkCountLabel(state.linkCount))
                    .font(.caption)
                    .foregroundStyle(Color(colors.inkSecondary))
            }
            LinkRow(
                links: state.links,
                tileFill: Color(colors.paper),
                tileInk: Color(colors.inkPrimary),
                titleColor: Color(colors.inkSecondary)
            )
        }
        .foregroundStyle(Color(colors.inkPrimary))
        .padding(14)
    }
}

/// The workspace's color with its monogram, drawn from the light palette so the letters
/// keep their contrast against the pastel fill on the black island.
private struct MonogramDisc: View {
    let state: StowActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        let palette = state.colors.light
        Circle()
            .fill(Color(rgb: palette.surface))
            .overlay {
                Text(state.monogram)
                    .font(.system(size: size * (state.monogram.count > 1 ? 0.4 : 0.5), weight: .bold, design: .rounded))
                    .foregroundStyle(Color(rgb: palette.inkPrimary))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(size * 0.12)
            }
            .frame(width: size, height: size)
            .accessibilityLabel(state.name)
    }
}

private struct LinkRow: View {
    let links: [StowActivityAttributes.TopLink]
    let tileFill: Color
    let tileInk: Color
    let titleColor: Color

    var body: some View {
        if links.isEmpty {
            Text("No links yet")
                .font(.caption)
                .foregroundStyle(titleColor)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: 6) {
                ForEach(links, id: \.self) { link in
                    if let destination = StowActivityAttributes.deepLink(for: link.url) {
                        SwiftUI.Link(destination: destination) {
                            tile(for: link)
                        }
                    } else {
                        tile(for: link)
                    }
                }
                // Keep tiles at a fixed width when there are fewer than six.
                ForEach(links.count..<StowActivityAttributes.maxLinks, id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
        }
    }

    private func tile(for link: StowActivityAttributes.TopLink) -> some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tileFill)
                .frame(width: 34, height: 34)
                .overlay {
                    Text(link.tileLetter)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(tileInk)
                }
            Text(link.title)
                .font(.system(size: 10))
                .foregroundStyle(titleColor)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(link.title)
        .accessibilityHint(link.host)
    }
}

private extension StowActivityAttributes.ContentState {
    var colors: StowTheme.Colors {
        StowTheme.colors(for: .custom(colorHex))
    }
}

private extension Color {
    init(rgb: StowTheme.RGB) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
