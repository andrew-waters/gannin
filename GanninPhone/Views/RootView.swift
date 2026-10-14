import SwiftUI

/// The lock screen until Face ID or the passcode passes, then the list of Macs.
struct RootView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        if lock.locked {
            LockView()
        } else {
            MacsView()
        }
    }
}

struct LockView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text("Gannin Remote is locked").font(.headline)
            if let failure = lock.failure {
                Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("Unlock") { Task { await lock.unlock() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .task { await lock.unlock() }
    }
}
