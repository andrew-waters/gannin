import SwiftUI

struct SettingsView: View {
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
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
