import SwiftUI

/// The app's settings: General (account and activity), Sync (what's fetched
/// from GitHub and how often) and Storage, as panes.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
                    .frame(width: 440)
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") {
                SyncSettingsView()
                    .frame(width: 620)
                    .frame(minHeight: 560)
            }
            Tab("Storage", systemImage: "internaldrive") {
                StorageSettings()
                    .frame(width: 560)
                    .frame(minHeight: 520)
            }
        }
    }
}

struct GeneralSettings: View {
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @AppStorage("excludeDrafts") private var excludeDrafts = false
    @AppStorage("showHidden") private var showHidden = false

    var body: some View {
        Form {
            Section("Account") {
                if let viewer = auth.viewer {
                    LabeledContent("Signed in as") {
                        HStack(spacing: 6) {
                            Avatar(url: viewer.avatarUrl, size: 18)
                            Text(viewer.login)
                        }
                    }
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                        orgs.clear()
                    }
                } else {
                    Text("Not signed in").foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Exclude draft PRs", isOn: $excludeDrafts)
                Toggle("Show hidden PRs and issues", isOn: $showHidden)
                Text("Hide a PR or issue by right-clicking it. Hidden ones are left out of lists and counts; show them to find one and Unhide it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Pull requests and issues")
            }
            SessionSettingsSection()
            SessionPromptSettingsSection()
        }
        .formStyle(.grouped)
    }
}
