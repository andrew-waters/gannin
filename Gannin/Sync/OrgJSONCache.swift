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
/// of saves costs one write, and writes to the same file never overtake each
/// other: they share a serial queue.
///
/// `reset()` removes the folder at once and drops every write waiting or
/// begun before it, so a write that was queued ahead of a clear can't bring
/// the folder back. It waits for a write already running, as the lock covers
/// the write itself.
///
/// Never hop to the main actor from here: `drain()` waits on the queue from
/// the main thread at quit.
nonisolated final class OrgFileWriter: Sendable {
    private struct Waiting {
        let generation: Int
        let encode: @Sendable () -> Data?
    }

    private struct State {
        var generation = 0
        var waiting: [String: Waiting] = [:]
    }

    private let cache: OrgJSONCache
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "dev.andon.gannin.org-files")

    init(cache: OrgJSONCache) {
        self.cache = cache
    }

    /// Writes `value` as `org`'s file, soon.
    func save<Value: Encodable & Sendable>(_ value: Value, org: String) {
        let encode: @Sendable () -> Data? = { try? OrgJSONCache.makeEncoder().encode(value) }
        state.withLock { $0.waiting[org] = Waiting(generation: $0.generation, encode: encode) }
        queue.async { [self] in write(org) }
    }

    /// Removes every org's file and forgets writes not yet made.
    func reset() {
        state.withLock { state in
            state.generation += 1
            state.waiting = [:]
            cache.clear()
        }
    }

    /// Waits for the writes handed over so far, for quit.
    func drain() {
        queue.sync {}
    }

    private func write(_ org: String) {
        guard let job = state.withLock({ $0.waiting.removeValue(forKey: org) }) else { return }
        // Encoding is the slow part, so it runs outside the lock.
        guard let data = job.encode() else { return }
        state.withLock { state in
            guard state.generation == job.generation else { return }
            try? FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
            try? data.write(to: cache.fileURL(org), options: .atomic)
        }
    }
}
