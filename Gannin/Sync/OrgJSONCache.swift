import Foundation
import os

/// A store's per-org JSON files in one folder of Application Support:
/// `<folder>/<org>.json`, dates as ISO 8601. Stores keep their own version
/// check, since what counts as an old format is theirs to say.
nonisolated struct OrgJSONCache: Sendable {
    let folder: String

    var directory: URL {
        AppPaths.support.appending(path: folder, directoryHint: .isDirectory)
    }

    /// What was saved for `org`, or nil when there's nothing or it can't be read.
    func load<Value: Decodable>(_ type: Value.Type, org: String) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(org)) else { return nil }
        return try? Self.makeDecoder().decode(type, from: data)
    }

    func save<Value: Encodable>(_ value: Value, org: String) {
        guard let data = try? Self.makeEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(org), options: .atomic)
    }

    /// Deletes every org's file.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The orgs with a saved file.
    func orgs() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            $0.deletingPathExtension().lastPathComponent.removingPercentEncoding
        }
    }

    func fileURL(_ org: String) -> URL {
        let safeOrg = org.addingPercentEncoding(withAllowedCharacters: Self.safeOrgCharacters) ?? org
        return directory.appending(path: "\(safeOrg).json")
    }

    /// Path-allowed characters less `/`, so an org name can't escape `directory`.
    private static let safeOrgCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    /// One per call: a coder is not safe to share between the main actor and
    /// the writer's queue.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Writes a store's per-org files, encoding them too, away from the main
/// actor. The newest value for an org replaces one still waiting, so a burst
/// of saves costs one write, and writes and removals share one serial queue,
/// so none overtakes another.
///
/// `reset()` drops every write waiting or encoded before it and queues the
/// removal of the folder behind a write already running, so a write begun
/// before a clear can't bring the folder back. Until the removal has run,
/// `isResetting` is true: a read then must treat the folder as empty.
///
/// The lock is held only to move state, never across the disk, because the
/// main actor takes it on every save. Never hop to the main actor from the
/// queue: `drain()` waits on it from the main thread at quit.
nonisolated final class OrgFileWriter: Sendable {
    private struct Waiting {
        let generation: Int
        let encode: @Sendable () -> Data?
    }

    private struct State {
        var generation = 0
        var resets = 0
        var waiting: [String: Waiting] = [:]
    }

    private let cache: OrgJSONCache
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "dev.andon.gannin.org-files")

    init(cache: OrgJSONCache) {
        self.cache = cache
    }

    /// Whether a `reset()` has not finished removing the folder.
    var isResetting: Bool { state.withLock { $0.resets > 0 } }

    /// Writes `value` as `org`'s file, soon.
    func save<Value: Encodable & Sendable>(_ value: Value, org: String) {
        let encode: @Sendable () -> Data? = { try? OrgJSONCache.makeEncoder().encode(value) }
        state.withLock { $0.waiting[org] = Waiting(generation: $0.generation, encode: encode) }
        queue.async { [self] in write(org) }
    }

    /// Forgets writes not yet made and removes every org's file, soon.
    func reset() {
        state.withLock { state in
            state.generation += 1
            state.resets += 1
            state.waiting = [:]
        }
        queue.async { [self] in
            cache.clear()
            state.withLock { $0.resets -= 1 }
        }
    }

    /// Waits for the writes and removals handed over so far, for quit.
    func drain() {
        queue.sync {}
    }

    private func write(_ org: String) {
        guard let job = state.withLock({ $0.waiting.removeValue(forKey: org) }) else { return }
        guard let data = job.encode() else { return }
        // A reset since the save was made has dropped it. One after this check
        // queues its removal behind this write, so the write can't outlive it.
        guard state.withLock({ $0.generation == job.generation }) else { return }
        try? FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try? data.write(to: cache.fileURL(org), options: .atomic)
    }
}
