import SwiftUI

/// The app's settings: General (account and activity) and Storage. Panes on
/// the Mac; on iPad, a form with Storage a page of its own.
struct SettingsView: View {
    var body: some View {
        #if os(macOS)
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
                    .frame(width: 440)
            }
            Tab("Storage", systemImage: "internaldrive") {
                StorageSettings()
                    .frame(width: 560)
                    .frame(minHeight: 520)
            }
        }
        #else
        GeneralSettings()
            .navigationTitle("Settings")
        #endif
    }
}

struct GeneralSettings: View {
    @Environment(AuthStore.self) private var auth
    @Environment(OrgStore.self) private var orgs
    @AppStorage(OrgStore.lookbackDaysKey) private var lookbackDays = OrgStore.defaultLookbackDays
    @AppStorage(ActionsStore.jobRunLimitKey) private var jobRunLimit = 0
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
            Section("Activity") {
                Stepper(value: $lookbackDays, in: 1...90) {
                    LabeledContent("Show merged work from the last", value: "\(lookbackDays) days")
                }
                Text("Applies on the next refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section {
                Picker("Jobs fetched per workflow", selection: $jobRunLimit) {
                    ForEach(ActionsStore.jobRunLimitOptions, id: \.self) { limit in
                        Text(limit == 0 ? "Every run in the window" : "Latest \(limit) runs").tag(limit)
                    }
                }
                Text("When you open a workflow on the Actions page, each run's jobs are one request to GitHub, so a busy workflow over 90 days can take thousands and a while to fetch. Lower this to fetch fewer; jobs already fetched are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("GitHub Actions")
            }
            #if os(macOS)
            SessionSettingsSection()
            SessionPromptSettingsSection()
            #endif
            #if !os(macOS)
            Section {
                NavigationLink("Storage") {
                    StorageSettings()
                        .navigationTitle("Storage")
                }
            }
            #endif
        }
        .formStyle(.grouped)
    }
}
