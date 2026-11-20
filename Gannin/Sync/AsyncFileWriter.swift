import Foundation
import os

/// Writes files away from the main actor: a file per key under one folder,
/// encoded where it is written.
///
/// Work is handed over from synchronous code, in order, through an
/// `AsyncStream` that one task consumes, so a removal queued after a write
/// runs after it and nothing else writes: a stale write can't land over a
/// newer one. The newest value for a key replaces one the task hasn't started,
/// so a burst of saves costs one write.
///
/// `flush()` is for quit, where nothing can `await`: it blocks the calling
/// thread until the task has run everything handed over before it, for at most
/// a few seconds. That is a synchronous wait on Swift concurrency, which can
/// deadlock if the task cannot get a thread, and the timeout turns that into a
/// delay at quit and possibly a lost save. `settle()` is the async wait.
///
/// `reset()` drops every save still waiting and asks for the folder to be
/// removed. Each save belongs to the generation it was made in, and a write
/// takes only a save from its own generation, so a save made after a reset is
/// written after the removal. While a removal is still asked for but not done,
/// `isResetting` is true, and a read must treat the folder as empty.
nonisolated final class AsyncFileWriter: Sendable {
    private enum Operation: Sendable {
        case write(key: String, generation: Int)
        case reset
        case removeFolder(URL)
        case barrier(@Sendable () -> Void)
    }

    private struct Waiting {
        let generation: Int
        let encode: @Sendable () -> Data?
    }

    private struct State {
        var generation = 0
        /// Removals of `directory` that `reset()` has asked for and the task
        /// has not done yet.
        var pendingRemovals = 0
        var waiting: [String: Waiting] = [:]
    }

    /// What the consumer task needs, so the task never holds the writer and
    /// the writer can end it by finishing the stream when it is released.
    private final class Core: Sendable {
        let directory: URL
        let fileURL: @Sendable (String) -> URL
        /// The waiting saves and counters. Held only to move them, because the
        /// main actor takes it on every `save` and `reset`.
        let state = OSAllocatedUnfairLock(initialState: State())

        init(directory: URL, fileURL: @escaping @Sendable (String) -> URL) {
            self.directory = directory
            self.fileURL = fileURL
        }

        func perform(_ operation: Operation) {
            switch operation {
            case .write(let key, let generation):
                let job = state.withLock { state -> Waiting? in
                    guard let waiting = state.waiting[key], waiting.generation == generation else { return nil }
                    state.waiting[key] = nil
                    return waiting
                }
                if let job { write(job, key: key) }
            case .reset:
                try? FileManager.default.removeItem(at: directory)
                // Counted done only now. `isResetting` stays true until the
                // files are gone, so a read in the meantime isn't served from them.
                state.withLock { $0.pendingRemovals -= 1 }
            case .removeFolder(let folder):
                // Not awaited, so a large folder doesn't hold up later writes.
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
            case .barrier(let done):
                done()
            }
        }

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

    /// Whether a `reset()` has asked for the folder to be removed and the task
    /// has not removed it yet.
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
    /// this returns; `isResetting` is true until it has.
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

    /// Blocks the calling thread until the task has run everything handed over
    /// before this call, or `timeout` has passed. For quit, where nothing can
    /// await. Never call it from the writer's own task.
    func flush(timeout: DispatchTimeInterval = .seconds(3)) {
        let done = DispatchSemaphore(value: 0)
        guard case .enqueued = continuation.yield(.barrier { done.signal() }) else { return }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Returns once the task has run everything handed over before the call.
    func settle() async {
        await withCheckedContinuation { barrier in
            if case .terminated = continuation.yield(.barrier { barrier.resume() }) { barrier.resume() }
        }
    }
}
