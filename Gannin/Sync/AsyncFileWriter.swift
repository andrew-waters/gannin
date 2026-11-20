import Foundation
import os

/// Writes files away from the main actor: a file per key under one folder,
/// encoded where it is written.
///
/// Work is handed over from synchronous code, in order, through an
/// `AsyncStream` that one task consumes, so a removal queued after a write
/// runs after it. The newest value for a key replaces one the task hasn't
/// started, so a burst of saves costs one write.
///
/// Nothing can wait for that task from synchronous code, so quit calls
/// `flush()`, which does the pending work itself. Both take `writeLock` for a
/// whole write, so `flush()` waits for one already running and nothing is
/// written twice or out of order. `settle()` is the async wait, for tests.
///
/// `reset()` drops every save still waiting and asks for the folder to be
/// removed. Each save belongs to the generation it was made in, and a write
/// takes only a save from its own generation, so a save made after a reset is
/// written after the removal. While a removal is still asked for but not done,
/// `isResetting` is true, and a read must treat the folder as empty.
///
/// Take `writeLock` before `state`, never the reverse, and never wait on the
/// main actor from the consumer.
nonisolated final class AsyncFileWriter: Sendable {
    private enum Operation: Sendable {
        case write(key: String, generation: Int)
        case reset
        case removeFolder(URL)
        case barrier(CheckedContinuation<Void, Never>)
    }

    private struct Waiting {
        let generation: Int
        let encode: @Sendable () -> Data?
    }

    private struct State {
        var generation = 0
        /// Removals of `directory` that `reset()` has asked for and no one has
        /// done yet.
        var pendingRemovals = 0
        var waiting: [String: Waiting] = [:]
    }

    /// What the consumer task needs, so the task never holds the writer and
    /// the writer can end it by finishing the stream when it is released.
    private final class Core: Sendable {
        let directory: URL
        let fileURL: @Sendable (String) -> URL
        /// The waiting saves and counters. Held only to move them, never across
        /// the disk, because the main actor takes it on every `save` and `reset`.
        let state = OSAllocatedUnfairLock(initialState: State())
        /// Held by the consumer task and by `flush()` for a whole take, encode
        /// and write. Without it `flush()` could write a newer save and then
        /// have an older one the task had already taken land over it, or return
        /// while the task still held the only waiting save. Only `flush()` takes
        /// it from another thread, so the main actor never waits on it elsewhere.
        let writeLock = NSLock()

        init(directory: URL, fileURL: @escaping @Sendable (String) -> URL) {
            self.directory = directory
            self.fileURL = fileURL
        }

        func perform(_ operation: Operation) {
            switch operation {
            case .write(let key, let generation):
                writeLock.withLock {
                    let job = state.withLock { state -> Waiting? in
                        guard let waiting = state.waiting[key], waiting.generation == generation else { return nil }
                        state.waiting[key] = nil
                        return waiting
                    }
                    if let job { write(job, key: key) }
                }
            case .reset:
                writeLock.withLock { removeDirectoryIfAsked(all: false) }
            case .removeFolder(let folder):
                // Not awaited, so a large folder doesn't hold up later writes.
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
            case .barrier(let continuation):
                continuation.resume()
            }
        }

        func flush() {
            writeLock.withLock {
                removeDirectoryIfAsked(all: true)
                let jobs = state.withLock { state -> [String: Waiting] in
                    defer { state.waiting = [:] }
                    return state.waiting
                }
                for (key, job) in jobs { write(job, key: key) }
            }
        }

        /// Removes `directory` if a `reset()` has asked for it and it has not
        /// been done. One removal answers one request, or all of them when
        /// `all` is set: a second removal would find nothing to remove.
        /// Called with `writeLock` held.
        private func removeDirectoryIfAsked(all: Bool) {
            guard state.withLock({ $0.pendingRemovals > 0 }) else { return }
            try? FileManager.default.removeItem(at: directory)
            // Counted done only now. `isResetting` stays true until the files
            // are gone, so a read in the meantime isn't served from them.
            state.withLock { $0.pendingRemovals = all ? 0 : $0.pendingRemovals - 1 }
        }

        /// Called with `writeLock` held.
        private func write(_ job: Waiting, key: String) {
            guard let data = job.encode() else { return }
            let url = fileURL(key)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // The folder is missing: before the first write, or after a reset.
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private let core: Core
    private let continuation: AsyncStream<Operation>.Continuation

    init(directory: URL, fileURL: @escaping @Sendable (String) -> URL) {
        let core = Core(directory: directory, fileURL: fileURL)
        let (stream, continuation) = AsyncStream.makeStream(of: Operation.self)
        self.core = core
        self.continuation = continuation
        Task.detached {
            for await operation in stream { core.perform(operation) }
        }
    }

    deinit {
        continuation.finish()
    }

    /// Whether a `reset()` has asked for the folder to be removed and it has
    /// not been removed yet.
    var isResetting: Bool { core.state.withLock { $0.pendingRemovals > 0 } }

    /// Writes what `encode` returns as `key`'s file, on the writer's task, so
    /// `encode` must not touch the main actor. A later save for the same key
    /// replaces this one if the task hasn't started it.
    func save(_ key: String, encode: @escaping @Sendable () -> Data?) {
        let generation = core.state.withLock { state -> Int in
            state.waiting[key] = Waiting(generation: state.generation, encode: encode)
            return state.generation
        }
        continuation.yield(.write(key: key, generation: generation))
    }

    /// Drops every save not yet written and asks for the folder to be
    /// removed. The task does the removal, so it may not have happened when
    /// this returns; `isResetting` is true until it has, and `flush()` does it
    /// at once.
    func reset() {
        core.state.withLock { state in
            state.generation += 1
            state.pendingRemovals += 1
            state.waiting = [:]
        }
        continuation.yield(.reset)
    }

    /// Removes `folder` after the writes handed over so far. Nothing waits for
    /// it: quitting right after leaves the folder behind.
    func removeFolder(_ folder: URL) {
        continuation.yield(.removeFolder(folder))
    }

    /// Does the requested removal and the waiting writes now, on the calling
    /// thread, after any write already running. For quit, where nothing can
    /// await.
    func flush() {
        core.flush()
    }

    /// Returns once the work handed over before the call has run. Never call it
    /// on a quit path.
    func settle() async {
        await withCheckedContinuation { barrier in
            if case .terminated = continuation.yield(.barrier(barrier)) { barrier.resume() }
        }
    }
}
