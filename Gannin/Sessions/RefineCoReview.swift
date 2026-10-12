import Foundation

/// What Claude keeps in a Design and Refine session's `refine.json`, in
/// its folder: where each finding most likely lives in the code, and
/// findings it suggests from screenshots or the transcript, for the room
/// to keep or dismiss. Its keys are snake case, and it's read leniently:
/// anything that doesn't decode is left out rather than losing the file.
struct RefineState: Codable, Hashable {
    /// Where a finding lives, by the finding's id.
    struct Scouting: Codable, Hashable {
        var finding: String
        var files: [String] = []
        var components: [String] = []
        var why: String?

        init(finding: String, files: [String] = [], components: [String] = [], why: String? = nil) {
            self.finding = finding
            self.files = files
            self.components = components
            self.why = why
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            finding = try c.decode(String.self, forKey: .finding)
            files = c.list(String.self, .files)
            components = c.list(String.self, .components)
            why = c.lenient(String.self, .why)
        }
    }

    /// A finding Claude suggests that the room didn't raise.
    struct Suggestion: Codable, Hashable, Identifiable {
        enum Source: String, Codable {
            case screenshot
            case transcript
        }

        var id: String
        var note: String
        var why: String?
        var source: Source?
        /// The screenshot it came from, by id.
        var screenshot: String?
        var files: [String] = []

        init(id: String, note: String, why: String? = nil, source: Source? = nil, screenshot: String? = nil, files: [String] = []) {
            self.id = id
            self.note = note
            self.why = why
            self.source = source
            self.screenshot = screenshot
            self.files = files
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            note = try c.decode(String.self, forKey: .note)
            why = c.lenient(String.self, .why)
            source = c.lenient(Source.self, .source)
            screenshot = c.lenient(String.self, .screenshot)
            files = c.list(String.self, .files)
        }
    }

    var scouting: [Scouting] = []
    var suggestions: [Suggestion] = []

    init(scouting: [Scouting] = [], suggestions: [Suggestion] = []) {
        self.scouting = scouting
        self.suggestions = suggestions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scouting = c.list(Scouting.self, .scouting)
        suggestions = c.list(Suggestion.self, .suggestions)
    }

    /// Read from Claude's file, whose keys are snake case.
    static func read(_ data: Data) -> RefineState? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(RefineState.self, from: data)
    }

    /// Where a finding lives, once Claude has looked.
    func scouting(for finding: UUID) -> Scouting? {
        scouting.last { $0.finding.caseInsensitiveCompare(finding.uuidString) == .orderedSame }
    }

    /// What Gannin tells the session about the two files it shares with it.
    static func instructions(folder: String) -> String {
        """
        ## Working with the room

        Gannin keeps `\(folder)/findings.json` up to date with what the room has noted: each finding's id, note, the page's \
        address and title, and the screenshots attached to it (paths in `\(folder)/screenshots/`). Each new finding, \
        screenshot or transcript is also pasted to you as it comes; reread the file whenever you're told something changed.

        Keep `\(folder)/refine.json` up to date, rewriting the whole file as JSON in this shape:

        {"scouting": [{"finding": "<finding id>", "files": ["owner/name:path or path#L10-L24"], "components": ["the views, components or modules"], "why": "a line on why it's there"}], "suggestions": [{"id": "s1", "note": "what to improve, as the room would put it", "why": "what you saw", "source": "screenshot" | "transcript", "screenshot": "<screenshot id>, when it came from one", "files": ["where it likely lives"]}]}

        - For each finding, scout the code in the picked repos and add where it most likely lives. Work through them in the \
        order they came, and write the file after each, so the room sees it as you go.
        - Look at each screenshot (read the image) and suggest findings the room didn't raise: rough edges in layout, copy, \
        contrast, states or consistency. Only what's worth an issue; it's fine to suggest nothing.
        - Give each suggestion a new id and never reuse one. Keep a suggestion in the file after the room keeps or dismisses \
        it; Gannin tracks which.
        - Edit nothing but `refine.json`: no code, no commits, no issues, no pull requests.
        """
    }
}

extension SessionStore {
    /// Writes what the room has noted to `findings.json` in the session's
    /// folder for Claude to read, and pastes it a note of what changed.
    func tellReviewer(_ id: UUID, _ message: String) {
        writeRoomFile(id)
        submit(message, to: id)
    }

    /// `findings.json` in the session's folder: the room's findings and
    /// screenshots, as Claude reads them.
    func writeRoomFile(_ id: UUID) {
        guard let session = sessions[id], let info = session.refine,
              let folder = Self.worktree(for: session) else { return }
        let screenshots = Dictionary(uniqueKeysWithValues: info.screenshots.map { ($0.id, $0) })
        let room = RefineRoomFile(
            page: info.url,
            findings: info.findings.map { finding in
                .init(id: finding.id.uuidString, note: finding.note, url: finding.url, pageTitle: finding.pageTitle, at: finding.at,
                      screenshots: finding.screenshots.compactMap { screenshots[$0].map { "screenshots/\($0.file)" } },
                      fromSuggestion: finding.suggestion)
            },
            screenshots: info.screenshots.map { .init(id: $0.id.uuidString, file: "screenshots/\($0.file)", url: $0.url) },
            transcript: info.transcript
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(room) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appending(path: "findings.json"), options: .atomic)
    }

    /// Reads `refine.json` again and keeps it with the session when it's
    /// changed. The session is always on this Mac.
    func refreshRefine(_ id: UUID) async {
        guard let session = sessions[id], session.refine != nil, let folder = Self.worktree(for: session) else { return }
        let url = folder.appending(path: "refine.json")
        let data = await Task.detached { try? Data(contentsOf: url) }.value
        guard let data, !data.isEmpty, let state = RefineState.read(data), sessions[id]?.refine?.state != state else { return }
        update(id) { $0.refine?.state = state }
    }

    /// Keeps a suggestion of Claude's: it becomes a finding, marked as
    /// Claude's, with the screenshot it came from.
    func keepSuggestion(_ suggestion: RefineState.Suggestion, in id: UUID) {
        guard let info = sessions[id]?.refine, !info.findings.contains(where: { $0.suggestion == suggestion.id }) else { return }
        let shot = suggestion.screenshot.flatMap { id in info.screenshots.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame } }
        let finding = RefineInfo.Finding(note: suggestion.note, url: shot?.url ?? info.lastURL ?? info.url, pageTitle: shot?.pageTitle,
                                         at: .now, screenshots: shot.map { [$0.id] } ?? [], suggestion: suggestion.id)
        update(id) { $0.refine?.findings.append(finding) }
        tellReviewer(id, "The room kept your suggestion \(suggestion.id) as finding \(finding.id.uuidString). Scout it if you haven't, and update refine.json.")
    }

    /// Dismisses a suggestion of Claude's.
    func dismissSuggestion(_ suggestion: RefineState.Suggestion, in id: UUID) {
        update(id) { session in
            let dismissed = session.refine?.dismissed ?? []
            if !dismissed.contains(suggestion.id) { session.refine?.dismissed = dismissed + [suggestion.id] }
        }
    }
}

extension RefineInfo {
    /// Claude's suggestions the room hasn't kept or dismissed yet.
    var openSuggestions: [RefineState.Suggestion] {
        let kept = Set(findings.compactMap(\.suggestion))
        let dismissed = Set(dismissed ?? [])
        return (state?.suggestions ?? []).filter { !kept.contains($0.id) && !dismissed.contains($0.id) }
    }
}

/// `findings.json`: what the room has noted, for Claude.
private struct RefineRoomFile: Encodable {
    struct Finding: Encodable {
        let id: String
        let note: String
        let url: String
        let pageTitle: String?
        let at: Date
        let screenshots: [String]
        let fromSuggestion: String?
    }

    struct Screenshot: Encodable {
        let id: String
        let file: String
        let url: String
    }

    let page: String
    let findings: [Finding]
    let screenshots: [Screenshot]
    let transcript: String?
}
