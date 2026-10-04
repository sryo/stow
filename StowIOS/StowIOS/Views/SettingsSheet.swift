import ActivityKit
import SwiftUI
import StowShared

/// Replaces the About sheet. "On this iPhone" holds what stays on this device, and
/// "Everywhere" the one choice that syncs with the Mac. Share and widget destinations
/// are explained in footers because they're chosen where they happen.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    @StateObject private var icloud = ICloudStatusMonitor()
    @State private var showInIsland = LiveActivitySettings().isEnabled
    @State private var shows = LiveActivitySettings().shows
    @State private var systemAllowsActivities = ActivityAuthorizationInfo().areActivitiesEnabled

    private static let sourceURL = URL(string: "https://github.com/sryo/stow")!

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    icloudRow
                }

                Section {
                    Toggle(isOn: $showInIsland) {
                        HStack(spacing: 10) {
                            SettingsIcon(color: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)) {
                                Capsule().fill(.white).frame(width: 14, height: 6)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Dynamic Island & Lock Screen")
                                if !systemAllowsActivities {
                                    Text("Live Activities are off for Stow in iOS Settings.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.island")
                    .onChange(of: showInIsland) { _, isOn in
                        viewModel.liveActivitySettings.isEnabled = isOn
                        viewModel.refreshLiveActivity(force: true)
                    }

                    Picker(selection: $shows) {
                        ForEach(LiveActivitySettings.options(for: viewModel.workspaces), id: \.self) { option in
                            Text(option.title).tag(option.choice)
                        }
                    } label: {
                        Text("Shows").padding(.leading, 38)
                    }
                    .pickerStyle(.navigationLink)
                    .disabled(!showInIsland)
                    .accessibilityIdentifier("settings.shows")
                    .onChange(of: shows) { _, choice in
                        viewModel.liveActivitySettings.shows = choice
                        viewModel.refreshLiveActivity(force: true)
                    }
                } header: {
                    SectionHeader("On this iPhone")
                } footer: {
                    Text("Sharing a link saves to the workspace you last opened. Pick another in the share sheet.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            SettingsIcon(color: Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)) {
                                Image(systemName: "paintpalette")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            Text("Page color")
                        }
                        PageColorPicker(
                            selection: viewModel.pageColor,
                            workspaceColor: viewModel.currentWorkspace.colorId,
                            onSelect: viewModel.setPageColor
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    SectionHeader("Everywhere")
                } footer: {
                    Text("Syncs with Stow on your Mac.")
                }

                Section {
                    LabeledContent("Version", value: version)
                    Link("Source on GitHub", destination: Self.sourceURL)
                } header: {
                    SectionHeader("About")
                } footer: {
                    Text("Long-press a Stow widget to choose its workspace.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            systemAllowsActivities = ActivityAuthorizationInfo().areActivitiesEnabled
            icloud.start()
        }
        .onDisappear { icloud.stop() }
    }

    private var icloudRow: some View {
        HStack(spacing: 10) {
            SettingsIcon(color: Color(red: 0x0A / 255, green: 0x84 / 255, blue: 1)) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("iCloud")
            Spacer(minLength: 8)
            Text(icloud.line.text)
                .foregroundStyle(icloud.line.isError ? Color.red : Color.secondary)
                .accessibilityIdentifier("settings.icloud.status")
            if let action = icloud.line.action {
                Button(action == .retry ? "Try Again" : "Fix") { icloud.performAction() }
                    .buttonStyle(.borderless)
                    .font(.body.weight(.semibold))
            }
        }
    }
}

/// The 28pt rounded-square glyph tile Settings rows lead with.
private struct SettingsIcon<Glyph: View>: View {
    let color: Color
    @ViewBuilder let glyph: Glyph

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color)
            .frame(width: 28, height: 28)
            .overlay { glyph }
            .accessibilityHidden(true)
    }
}

/// Small uppercase group labels, as in the approved mockup.
private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.footnote)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}
