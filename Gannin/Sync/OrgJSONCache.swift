import Foundation

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
    /// the writer's task.
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

nonisolated extension AsyncFileWriter {
    /// A writer for the files of `cache`, keyed by org.
    convenience init(cache: OrgJSONCache) {
        self.init(directory: cache.directory, fileURL: { cache.fileURL($0) })
    }

    /// Writes `value` as `org`'s file, soon.
    func save<Value: Encodable & Sendable>(_ value: Value, org: String) {
        save(org) { try? OrgJSONCache.makeEncoder().encode(value) }
    }
}
