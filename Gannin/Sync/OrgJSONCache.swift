import Foundation

/// A store's per-org JSON files in one folder of Application Support:
/// `<folder>/<org>.json`, dates as ISO 8601. Stores keep their own version
/// check, since what counts as an old format is theirs to say.
struct OrgJSONCache {
    let folder: String

    var directory: URL {
        URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory)
    }

    /// What was saved for `org`, or nil when there's nothing or it can't be read.
    func load<Value: Decodable>(_ type: Value.Type, org: String) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(org)) else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }

    func save<Value: Encodable>(_ value: Value, org: String) {
        guard let data = try? Self.encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(org), options: .atomic)
    }

    /// Deletes every org's file.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL(_ org: String) -> URL {
        let safeOrg = org.addingPercentEncoding(withAllowedCharacters: Self.safeOrgCharacters) ?? org
        return directory.appending(path: "\(safeOrg).json")
    }

    /// Path-allowed characters less `/`, so an org name can't escape `directory`.
    private static let safeOrgCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
