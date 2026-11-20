import Foundation
import os

/// Writes `Sessions.json` and removes a forgotten session's folder away from
/// the main actor, in the order they were asked for.
///
/// Writes share one serial queue and the newest data replaces one still
/// waiting, so a burst of saves costs one write. A folder is removed only
/// after every write queued before it has landed, so a session never
/// reappears from a `Sessions.json` older than its folder's removal.
///
/// Never put slow work on `queue`: `drain()` waits for it, and runs at quit.
nonisolated final class SessionFileWriter: Sendable {
    private let queue = DispatchQueue(label: "dev.andon.gannin.session-files")
    private let pending = OSAllocatedUnfairLock<(data: Data, url: URL)?>(initialState: nil)

    /// Writes `data` to `url` atomically, creating its folder if needed.
    func write(_ data: Data, to url: URL) {
        pending.withLock { $0 = (data, url) }
        queue.async { [pending] in
            guard let job = pending.withLock({ state -> (data: Data, url: URL)? in
                defer { state = nil }
                return state
            }) else { return }
            try? FileManager.default.createDirectory(at: job.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? job.data.write(to: job.url, options: .atomic)
        }
    }

    /// Removes `folder` once the writes queued so far have landed. The
    /// removal itself runs on another queue, so a large folder doesn't hold
    /// up `drain()`.
    func removeFolder(_ folder: URL) {
        queue.async {
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Waits for the writes queued so far, for quit. Don't call it from a
    /// queue a write waits on.
    func drain() {
        queue.sync {}
    }
}
