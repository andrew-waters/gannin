import Foundation

/// Matching sessions against typed words, for the grid and the + popover.
enum SessionSearch {
    /// The typed words, lowercased; empty when nothing is typed.
    static func words(_ search: String) -> [String] {
        search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether every word is in the session's kind, reference, title, repo,
    /// branch or pull requests' repo, number and title.
    static func matches(_ session: CodeSession, words: [String], pullRequests: [SessionPullRequest] = []) -> Bool {
        guard !words.isEmpty else { return true }
        let kind = TabKind(session)
        let fields = [kind.name, kind.reference ?? "", kind.title, session.title, session.issue.repo, session.branch]
            + pullRequests.flatMap { ["\($0.repo)#\($0.number)", $0.title] }
        let text = fields.joined(separator: " ").lowercased()
        return words.allSatisfy { text.contains($0) }
    }
}
