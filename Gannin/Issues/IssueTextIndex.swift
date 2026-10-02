import Foundation
import SQLite3

/// An issue's words, for the search index.
nonisolated struct IssueText: Sendable {
    let id: String
    let org: String
    let repo: String
    let number: Int
    let title: String
    let body: String
    /// Recent comments, each "@login: text".
    let comments: String
    let updatedAt: Date
}

/// An issue the search found: where, and the passage that matched with its
/// matching words marked `[[` and `]]`.
nonisolated struct IssueTextHit: Sendable, Identifiable, Hashable {
    let id: String
    let repo: String
    let number: Int
    let title: String
    let snippet: String
}

/// Issues' titles, descriptions and recent comments, in a SQLite full-text
/// index (FTS5, with stemming) in Application Support, filled by the issue
/// deep sync. Searches rank titles above descriptions above comments, take
/// every word (each as a prefix, so it works as you type) or a "quoted
/// phrase", and return the passage that matched.
actor IssueTextIndex {
    static let shared = IssueTextIndex()

    private var db: OpaquePointer?

    static var file: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.andon.getgannin", directoryHint: .isDirectory)
            .appending(path: "IssueText.sqlite")
    }

    private func open() -> OpaquePointer? {
        if let db { return db }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(Self.file.path, &handle) == SQLITE_OK else { return nil }
        db = handle
        execute("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS docs(id TEXT PRIMARY KEY, org TEXT NOT NULL, repo TEXT NOT NULL, number INTEGER NOT NULL, title TEXT NOT NULL, updated REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS docs_org ON docs(org);
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(id UNINDEXED, org UNINDEXED, title, body, comments, tokenize='porter unicode61');
            CREATE TABLE IF NOT EXISTS synced(org TEXT PRIMARY KEY, at REAL NOT NULL);
            """)
        return db
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func statement(_ sql: String) -> OpaquePointer? {
        guard let db = open() else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ values: [Any]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            case let number as Double: sqlite3_bind_double(statement, index, number)
            default: sqlite3_bind_null(statement, index)
            }
        }
    }

    private func run(_ sql: String, _ values: [Any] = []) {
        guard let statement = statement(sql) else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        sqlite3_step(statement)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    // MARK: Writing

    func upsert(_ texts: [IssueText]) {
        guard open() != nil, !texts.isEmpty else { return }
        execute("BEGIN")
        for text in texts {
            run("DELETE FROM fts WHERE id = ?", [text.id])
            run("INSERT INTO fts(id, org, title, body, comments) VALUES (?, ?, ?, ?, ?)", [text.id, text.org, text.title, text.body, text.comments])
            run("INSERT OR REPLACE INTO docs(id, org, repo, number, title, updated) VALUES (?, ?, ?, ?, ?, ?)",
                [text.id, text.org, text.repo, text.number, text.title, text.updatedAt.timeIntervalSince1970])
        }
        execute("COMMIT")
    }

    /// Issue IDs indexed for the org.
    func indexed(org: String) -> Set<String> {
        guard let statement = statement("SELECT id FROM docs WHERE org = ?") else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, [org])
        var ids: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW { ids.insert(Self.text(statement, 0)) }
        return ids
    }

    func lastSync(org: String) -> Date? {
        guard let statement = statement("SELECT at FROM synced WHERE org = ?") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, [org])
        return sqlite3_step(statement) == SQLITE_ROW ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)) : nil
    }

    func setLastSync(org: String, _ date: Date) {
        run("INSERT OR REPLACE INTO synced(org, at) VALUES (?, ?)", [org, date.timeIntervalSince1970])
    }

    func clear() {
        if let db { sqlite3_close(db) }
        db = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(filePath: Self.file.path + suffix))
        }
    }

    // MARK: Searching

    /// The best matches for the words typed, most relevant first.
    func search(org: String, text: String, limit: Int = 80) -> [IssueTextHit] {
        guard let match = Self.matchExpression(text), let statement = statement("""
            SELECT fts.id, docs.repo, docs.number, docs.title, snippet(fts, -1, '[[', ']]', '', 16)
            FROM fts JOIN docs ON docs.id = fts.id
            WHERE fts MATCH ? AND fts.org = ?
            ORDER BY bm25(fts, 0.0, 0.0, 10.0, 4.0, 1.0)
            LIMIT ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, [match, org, limit])
        var hits: [IssueTextHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            hits.append(IssueTextHit(
                id: Self.text(statement, 0), repo: Self.text(statement, 1), number: Int(sqlite3_column_int64(statement, 2)),
                title: Self.text(statement, 3), snippet: Self.text(statement, 4)
            ))
        }
        return hits
    }

    /// The words typed as an FTS5 query: each word a prefix ("analyt*"),
    /// "quoted phrases" kept whole, all of them required.
    nonisolated static func matchExpression(_ text: String) -> String? {
        var terms: [String] = []
        var rest = Substring(text)
        func clean(_ word: Substring) -> String {
            String(word.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
                .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        while let quote = rest.firstIndex(of: "\"") {
            for word in rest[..<quote].split(whereSeparator: \.isWhitespace) {
                let word = clean(word)
                if !word.isEmpty { terms.append("\"\(word)\"*") }
            }
            let after = rest.index(after: quote)
            if let close = rest[after...].firstIndex(of: "\"") {
                let phrase = rest[after..<close].split(whereSeparator: \.isWhitespace).map(clean).filter { !$0.isEmpty }
                if !phrase.isEmpty { terms.append("\"\(phrase.joined(separator: " "))\"") }
                rest = rest[rest.index(after: close)...]
            } else {
                rest = rest[after...]
            }
        }
        for word in rest.split(whereSeparator: \.isWhitespace) {
            let word = clean(word)
            if !word.isEmpty { terms.append("\"\(word)\"*") }
        }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }
}
