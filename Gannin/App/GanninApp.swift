import SwiftUI

@main
struct GanninApp: App {
    @State private var auth: AuthStore
    @State private var orgs: OrgStore
    @State private var details: DetailStore
    @State private var hidden = HiddenStore()
    @State private var metrics: MetricsStore
    @State private var workLog: WorkLogStore
    @State private var orgConfigs = OrgConfigStore()
    @State private var activity: SyncActivity

    init() {
        let auth = AuthStore()
        let activity = SyncActivity()
        _auth = State(initialValue: auth)
        _activity = State(initialValue: activity)
        _orgs = State(initialValue: OrgStore(auth: auth, activity: activity))
        _details = State(initialValue: DetailStore(auth: auth))
        _metrics = State(initialValue: MetricsStore(auth: auth, activity: activity))
        _workLog = State(initialValue: WorkLogStore(auth: auth, activity: activity))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(orgs)
                .environment(details)
                .environment(hidden)
                .environment(metrics)
                .environment(workLog)
                .environment(orgConfigs)
                .environment(activity)
        }
        .defaultSize(width: 1280, height: 800)

        // A PR opened from the work log; one window per PR.
        WindowGroup("Pull Request", for: PullRequestReference.self) { $reference in
            if let reference {
                PullRequestWindow(reference: reference)
                    .environment(auth)
                    .environment(orgs)
                    .environment(details)
                    .environment(hidden)
                    .environment(metrics)
                    .environment(workLog)
                    .environment(orgConfigs)
                    .environment(activity)
            }
        }
        .defaultSize(width: 560, height: 720)

        Settings {
            SettingsView()
                .environment(auth)
                .environment(orgs)
        }
    }
}

struct RootView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(DetailStore.self) private var details
    @Environment(WorkLogStore.self) private var workLog

    var body: some View {
        Group {
            if auth.isSignedIn {
                MainView()
            } else {
                SignInView()
            }
        }
        .task { await auth.validate() }
        .onChange(of: auth.isSignedIn) {
            if !auth.isSignedIn {
                details.clear()
                workLog.clear()
            }
        }
    }
}
