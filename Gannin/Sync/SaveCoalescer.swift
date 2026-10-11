import AppKit

/// Runs a store's save once for any number of requests made within `delay`,
/// for state that changes in bursts (a PR edited, then another; items opened
/// one after another) so a large file isn't rewritten for each. A save still
/// waiting is written when the app quits.
final class SaveCoalescer {
    private let delay: Duration
    private let write: () -> Void
    private var isScheduled = false

    /// Coalescers live as long as their store, which lives as long as the app,
    /// so the quit observer is never removed.
    init(delay: Duration = .seconds(1), write: @escaping () -> Void) {
        self.delay = delay
        self.write = write
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Saves soon, sharing the write with any requested in the meantime.
    func request() {
        guard !isScheduled else { return }
        isScheduled = true
        Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            self?.flush()
        }
    }

    /// Writes now if a save is waiting.
    func flush() {
        guard isScheduled else { return }
        isScheduled = false
        write()
    }

    /// Forgets a waiting save, for a store that has just deleted its file.
    func cancel() {
        isScheduled = false
    }
}
