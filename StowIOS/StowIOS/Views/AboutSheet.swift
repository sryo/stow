import SwiftUI

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage(LiveActivityController.enabledKey) private var showInDynamicIsland = true

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }

    private var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "—"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        Image("AppIcon")
                            .resizable()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stow")
                                .font(.title3.weight(.semibold))
                            Text("Workspace bookmarks for iOS")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Version \(version) (\(build))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }

                Section {
                    Toggle("Show in Dynamic Island", isOn: $showInDynamicIsland)
                        .onChange(of: showInDynamicIsland) { _, _ in
                            viewModel.refreshLiveActivity(force: true)
                        }
                } footer: {
                    Text("Keeps the current workspace and its top links in the Dynamic Island and on the Lock Screen.")
                }

                Section("Source") {
                    Link(destination: URL(string: "https://github.com/sryo/stow")!) {
                        Label("GitHub Repository", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
