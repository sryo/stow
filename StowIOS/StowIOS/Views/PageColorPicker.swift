import SwiftUI
import StowShared

/// Color / Neutral as a segmented control whose segments preview the open workspace's
/// page in each mode, as in the approved mockup.
struct PageColorPicker: View {
    let selection: StowTheme.TintMode
    let workspaceColor: WorkspaceColorId
    let onSelect: (StowTheme.TintMode) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PageColor.options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(.sRGB, red: 118 / 255, green: 118 / 255, blue: 128 / 255, opacity: colorScheme == .dark ? 0.24 : 0.12))
        )
    }

    private func segment(_ option: PageColor.Option) -> some View {
        let isOn = option.tint == selection
        return Button {
            onSelect(option.tint)
        } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color(uiColor: StowTheme.colors(for: workspaceColor, tint: option.tint).surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .strokeBorder(Color(white: 0.5, opacity: 0.4), lineWidth: 1)
                    )
                    .frame(width: 14, height: 10)
                Text(option.title)
                    .font(.system(size: 13, weight: isOn ? .semibold : .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(colorScheme == .dark ? Color(.sRGB, red: 99 / 255, green: 99 / 255, blue: 102 / 255) : .white)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}
