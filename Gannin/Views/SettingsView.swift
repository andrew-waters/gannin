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
