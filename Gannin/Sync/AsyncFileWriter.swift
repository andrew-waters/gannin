import Foundation
import os

/// Writes files away from the main actor: a file per key under one folder,
/// encoded where it is written.
///
/// Work is handed over from synchronous code, in order, through an
/// `AsyncStream` that one task consumes, so a removal queued after a write
/// runs after it. The newest value for a key replaces one still waiting, so a
/// burst of saves costs one write.
///
/// Nothing can wait for that task from synchronous code, so quit calls
/// `flush()`, which does the pending work itself. Both take `writeLock` for a
/// whole write, so `flush()` waits for one already running and nothing is
/// written twice or out of order. `settle()` is the async wait, for tests.
///
/// `reset()` drops every save still waiting and removes the folder. Each save
/// belongs to the generation it was made in, and a write takes only a save
/// from its own generation, so a save made after a reset is written after the
/// removal. A removal not yet done leaves `isResetting` true, and a read then
/// must treat the folder as empty.
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
        var resets = 0
        var waiting: [String: Waiting] = [:]
    }

    /// What the consumer task needs, so the task never holds the writer and
    /// the writer can end it by finishing the stream when it is released.
    private final class Core: Sendable {
        let directory: URL
        let fileURL: @Sendable (String) -> URL
        let state = OSAllocatedUnfairLock(initialState: State())
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
                writeLock.withLock {
                    guard state.withLock({ $0.resets > 0 }) else { return }
                    try? FileManager.default.removeItem(at: directory)
                    // Only now: until the folder is gone a read must see it as empty.
                    state.withLock { $0.resets -= 1 }
                }
            case .removeFolder(let folder):
                // Not awaited, so a large folder doesn't hold up later writes.
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
            case .barrier(let continuation):
                continuation.resume()
            }
        }

        func flush() {
            writeLock.withLock {
                if state.withLock({ $0.resets > 0 }) {
                    try? FileManager.default.removeItem(at: directory)
                    state.withLock { $0.resets = 0 }
                }
                let jobs = state.withLock { state -> [String: Waiting] in
                    defer { state.waiting = [:] }
                    return state.waiting
                }
                for (key, job) in jobs { write(job, key: key) }
            }
        }

        /// Called with `writeLock` held.
        private func write(_ job: Waiting, key: String) {
            guard let data = job.encode() else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL(key), options: .atomic)
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

    /// Whether a `reset()` has not finished removing the folder.
    var isResetting: Bool { core.state.withLock { $0.resets > 0 } }

    /// Writes what `encode` returns as `key`'s file, soon. `encode` runs on
    /// the writer's task, so it must not touch the main actor.
    func save(_ key: String, encode: @escaping @Sendable () -> Data?) {
        let generation = core.state.withLock { state -> Int in
            state.waiting[key] = Waiting(generation: state.generation, encode: encode)
            return state.generation
        }
        continuation.yield(.write(key: key, generation: generation))
    }

    /// Forgets saves not yet written and removes the folder, soon.
    func reset() {
        core.state.withLock { state in
            state.generation += 1
            state.resets += 1
            state.waiting = [:]
        }
        continuation.yield(.reset)
    }

    /// Removes `folder` after the writes handed over so far. Nothing waits for
    /// it: quitting right after leaves the folder behind.
    func removeFolder(_ folder: URL) {
        continuation.yield(.removeFolder(folder))
    }

    /// Does the pending removal and writes now, on the calling thread, after
    /// any write already running. For quit, where nothing can await.
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
