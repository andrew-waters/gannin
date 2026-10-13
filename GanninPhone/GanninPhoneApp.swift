import SwiftUI

@main
struct GanninPhoneApp: App {
    @State private var lock = AppLock()
    @State private var macs = PairedMacs()
    @State private var browser = MacBrowser()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(lock)
                .environment(macs)
                .environment(browser)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: lock.wentToBackground()
                    case .active: lock.becameActive()
                    default: break
                    }
                }
        }
    }
}
