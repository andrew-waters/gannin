import Foundation

/// REST responses kept with their ETag, so asking again sends
/// `If-None-Match` and GitHub answers 304 with no body and no cost to the
/// REST budget when nothing changed. Memory only, newest kept within
/// `byteLimit`, so a launch starts with none.
actor RESTCache {
    static let shared = RESTCache()

    struct Entry {
        let etag: String
        let data: Data
    }

    private let byteLimit: Int
    private var entries: [String: Entry] = [:]
    /// Keys in the order they were stored, oldest first.
    private var order: [String] = []
    private var bytes = 0

    init(byteLimit: Int = 20 * 1024 * 1024) {
        self.byteLimit = byteLimit
    }

    func entry(for key: String) -> Entry? {
        entries[key]
    }

    func store(_ data: Data, etag: String, for key: String) {
        // One response taking a quarter of the room would push out everything else.
        guard data.count <= byteLimit / 4 else {
            remove(key)
            return
        }
        remove(key)
        entries[key] = Entry(etag: etag, data: data)
        order.append(key)
        bytes += data.count
        while bytes > byteLimit, let oldest = order.first {
            remove(oldest)
        }
    }

    func removeAll() {
        entries = [:]
        order = []
        bytes = 0
    }

    private func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        bytes -= entry.data.count
        order.removeAll { $0 == key }
    }
}
