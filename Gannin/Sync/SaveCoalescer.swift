import AppKit

/// Runs a store's save once for any number of requests made within `delay`,
/// for state that changes in bursts (a PR edited, then another; items opened
/// one after another) so a large file isn't rewritten for each. A save still
/// waiting is written when the app quits.
final class SaveCoalescer {
    private let delay: Duration
    private let write: () -> Void
    private var task: Task<Void, Never>?
    nonisolated(unsafe) private var quitObserver: NSObjectProtocol?

    init(delay: Duration = .seconds(1), write: @escaping () -> Void) {
        self.delay = delay
        self.write = write
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }

    /// Saves soon, sharing the write with any requested in the meantime.
    func request() {
        guard task == nil else { return }
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes now if a save is waiting.
    func flush() {
        guard task != nil else { return }
        cancel()
        write()
    }

    /// Forgets a waiting save, for a store that has just deleted its file.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
