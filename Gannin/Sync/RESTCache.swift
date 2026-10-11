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
        fileprivate var sequence = 0
    }

    private let byteLimit: Int
    private var entries: [String: Entry] = [:]
    /// Keys in the order they were stored, oldest first, from `head`. An
    /// entry replaced or removed leaves its slot behind; it's told apart from
    /// the live one by its sequence number and skipped when reached, so
    /// neither costs a scan.
    private var order: [(key: String, sequence: Int)] = []
    private var head = 0
    private var nextSequence = 0
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
        nextSequence += 1
        entries[key] = Entry(etag: etag, data: data, sequence: nextSequence)
        order.append((key, nextSequence))
        bytes += data.count
        while bytes > byteLimit, head < order.count {
            let oldest = order[head]
            head += 1
            if entries[oldest.key]?.sequence == oldest.sequence { remove(oldest.key) }
        }
        // Reclaim the slots passed over once they're most of the array.
        if head > 64, head > order.count / 2 {
            order.removeFirst(head)
            head = 0
        }
    }

    func removeAll() {
        entries = [:]
        order = []
        head = 0
        bytes = 0
    }

    private func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        bytes -= entry.data.count
    }
}
