import Foundation
import GanninRemote
import LocalAuthentication
import Observation

/// Face ID or the passcode, asked at launch and after the app has been away a minute.
@MainActor
@Observable
final class AppLock {
    private(set) var locked = true
    private(set) var failure: String?
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private let policy = AppLockPolicy()

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        // With no passcode set there's nothing to check, so the app stays locked.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            failure = "Set a passcode on this iPhone to use Gannin Remote."
            return
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Gannin Remote")
            locked = false
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func wentToBackground() {
        backgroundedAt = .now
    }

    func becameActive() {
        if policy.shouldLock(backgroundedAt: backgroundedAt, now: .now) { locked = true }
        backgroundedAt = nil
    }
}
