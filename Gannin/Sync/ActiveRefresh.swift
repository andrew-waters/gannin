import AppKit

/// Runs `refresh` now, then after each `interval` while Gannin is the active
/// app. A tick that falls while it's in the background waits for it to become
/// active again and refreshes then. Throws when the calling task is cancelled.
func refreshWhileActive(every interval: Duration, _ refresh: () async -> Void) async throws {
    await refresh()
    while true {
        try await Task.sleep(for: interval)
        if !NSApp.isActive {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) { break }
            try Task.checkCancellation()
        }
        await refresh()
    }
}
