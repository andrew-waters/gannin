import SwiftUI

@main
struct GanninApp: App {
    @State private var auth: AuthStore
    @State private var orgs: OrgStore

    init() {
        let auth = AuthStore()
        _auth = State(initialValue: auth)
        _orgs = State(initialValue: OrgStore(auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(orgs)
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView()
                .environment(auth)
                .environment(orgs)
        }
    }
}

struct RootView: View {
    @Environment(AuthStore.self) private var auth

    var body: some View {
        Group {
            if auth.isSignedIn {
                MainView()
            } else {
                SignInView()
            }
        }
        .task { await auth.validate() }
    }
}
