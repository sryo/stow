import ActivityKit
import SwiftUI
import UIKit
import WidgetKit
import StowShared

/// The current workspace in the Dynamic Island and on the Lock Screen.
struct StowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StowActivityAttributes.self) { context in
            let style = StowActivityAttributes.LockScreenStyle(colorHex: context.state.colorHex)
            LockScreenView(state: context.state, style: style)
                .activityBackgroundTint(Color(rgb: style.background))
                .activitySystemActionForegroundColor(Color(rgb: style.name))
        } dynamicIsland: { context in
            let state = context.state
            let island = state.colors.dark
            let light = state.colors.light
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MonogramDisc(state: state, size: 36, fill: Color(rgb: light.surface), ink: Color(rgb: light.inkPrimary))
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
                MonogramDisc(state: state, size: 22, fill: Color(rgb: light.surface), ink: Color(rgb: light.inkPrimary))
            } compactTrailing: {
                Text("\(state.linkCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(rgb: light.surface))
                    .accessibilityLabel(linkCountLabel(state.linkCount))
            } minimal: {
                MonogramDisc(state: state, size: 22, fill: Color(rgb: light.surface), ink: Color(rgb: light.inkPrimary))
            }
            .keylineTint(Color(rgb: light.surface))
        }
    }
}

private func linkCountLabel(_ count: Int) -> String {
    count == 1 ? "1 link" : "\(count) links"
}

/// Drawn entirely from `style`, one palette, so the text always matches the card.
private struct LockScreenView: View {
    let state: StowActivityAttributes.ContentState
    let style: StowActivityAttributes.LockScreenStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MonogramDisc(state: state, size: 28, fill: Color(rgb: style.monogramFill), ink: Color(rgb: style.monogramInk))
                Text(state.name)
                    .font(.headline)
                    .foregroundStyle(Color(rgb: style.name))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(linkCountLabel(state.linkCount))
                    .font(.caption)
                    .foregroundStyle(Color(rgb: style.caption))
            }
            LinkRow(
                links: state.links,
                tileFill: Color(rgb: style.tileFill),
                tileInk: Color(rgb: style.tileInk),
                titleColor: Color(rgb: style.caption)
            )
        }
        .padding(14)
    }
}

/// The workspace's badge as the Mac's workspace tile draws it: its favicon mosaic, its
/// symbol, or its letters.
private struct MonogramDisc: View {
    let state: StowActivityAttributes.ContentState
    let size: CGFloat
    let fill: Color
    let ink: Color

    private var scale: CGFloat { size / 36 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 11 / 36, style: .continuous)
        shape
            .fill(fill)
            .overlay { content }
            .clipShape(shape)
            .frame(width: size, height: size)
            .accessibilityLabel(state.name)
    }

    @ViewBuilder
    private var content: some View {
        if let icons = state.badgeIcons, !icons.isEmpty {
            let inset = 4 * scale, gap = 2 * scale
            let cell = (size - inset * 2 - gap) / 2
            VStack(spacing: gap) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            let shape = RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                            if index < icons.count, let image = FaviconImage.load(icons[index]) {
                                Image(uiImage: image)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: cell, height: cell)
                                    .clipShape(shape)
                            } else {
                                shape.fill(Color.black.opacity(0.12)).frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
        } else if let symbol = state.badgeSymbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(ink)
        } else {
            Text(state.monogram)
                .font(.system(size: size * (state.monogram.count > 1 ? 0.4 : 0.48), weight: .heavy))
                .foregroundStyle(ink)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(size * 0.1)
        }
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
                    if let favicon = FaviconImage.load(link.iconFile) {
                        Image(uiImage: favicon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    } else {
                        Text(link.tileLetter)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(tileInk)
                    }
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

extension Color {
    init(rgb: StowTheme.RGB) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}
