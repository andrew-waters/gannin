import Foundation

// MARK: - The config

/// How Claude reviews a repo, in the spirit of CodeRabbit's
/// `.coderabbit.yaml`: how much to say, standing instructions, files to
/// skip, instructions for paths, checks a PR must pass, and PRs automatic
/// reviews leave alone. Kept in the project's harness as
/// `.gannin/review.json` (defaults for every repo, and a section per repo),
/// and optionally in a repo as `.gannin/review.json` on its default branch,
/// which wins for that repo (`ReviewConfig.Layers`). Edited in
/// `ReviewConfigSheet`, from a repository's page.
struct ReviewConfig: Codable, Hashable {
    enum Profile: String, Codable, CaseIterable, Identifiable {
        case quiet, chill, assertive

        var id: Self { self }
        var title: String { rawValue.capitalized }

        var help: String {
            switch self {
            case .quiet: "Only what matters: bugs, security and anything blocking. Nothing about style."
            case .chill: "Balanced: real problems and worthwhile improvements, few nits."
            case .assertive: "Thorough: everything worth saying, nits included."
            }
        }

        /// What the reviewer's told.
        var instructions: String {
            switch self {
            case .quiet: "Be quiet: raise only blockers and major findings (bugs, security, data loss, anything that would break). No minor findings or nits."
            case .chill: "Be balanced: raise real problems and improvements worth making. Keep nits to a minimum."
            case .assertive: "Be thorough: raise everything worth saying, including minor points and nits."
            }
        }
    }

    struct PathInstruction: Codable, Hashable, Identifiable {
        var id = UUID()
        var path: String
        var instructions: String

        enum CodingKeys: String, CodingKey { case path, instructions }
    }

    /// A check every PR is held to, judged by the reviewer.
    struct Check: Codable, Hashable, Identifiable {
        enum Mode: String, Codable, CaseIterable, Identifiable {
            case off, warning, error
            var id: Self { self }
            var title: String { rawValue.capitalized }
        }

        var id = UUID()
        var name: String
        var mode: Mode
        var instructions: String

        enum CodingKeys: String, CodingKey { case name, mode, instructions }
    }

    var profile: Profile?
    /// Standing guidance for every review.
    var instructions: String?
    /// How comments should sound.
    var tone: String?
    /// Globs of files not to review (generated code, lockfiles).
    var ignore: [String]?
    var pathInstructions: [PathInstruction]?
    var checks: [Check]?
    /// Automatic reviews leave PRs whose title has one of these alone.
    var skipTitleKeywords: [String]?

    var isEmpty: Bool { self == ReviewConfig() }

    /// `other` laid over this: its settings win, lists are added to
    /// (checks and path instructions by name and path, replacing).
    func overlaid(with other: ReviewConfig) -> ReviewConfig {
        var merged = self
        if let profile = other.profile { merged.profile = profile }
        if let text = other.instructions?.nonEmpty { merged.instructions = [instructions?.nonEmpty, text].compactMap { $0 }.joined(separator: "\n\n") }
        if let tone = other.tone?.nonEmpty { merged.tone = tone }
        if let ignore = other.ignore { merged.ignore = Self.unique((self.ignore ?? []) + ignore) }
        if let paths = other.pathInstructions {
            merged.pathInstructions = (pathInstructions ?? []).filter { mine in !paths.contains { $0.path == mine.path } } + paths
        }
        if let checks = other.checks {
            merged.checks = (self.checks ?? []).filter { mine in !checks.contains { $0.name.caseInsensitiveCompare(mine.name) == .orderedSame } } + checks
        }
        if let keywords = other.skipTitleKeywords { merged.skipTitleKeywords = Self.unique((skipTitleKeywords ?? []) + keywords) }
        return merged
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// Whether automatic reviews should leave a PR with this title alone.
    func skips(title: String) -> Bool {
        (skipTitleKeywords ?? []).contains { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }
    }

    func ignores(_ path: String) -> Bool {
        (ignore ?? []).contains { Glob.matches($0, path) }
    }

    /// A check's mode, by name; nil for one the config doesn't hold.
    func mode(of name: String) -> Check.Mode? {
        checks?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.mode
    }

    var activeChecks: [Check] { (checks ?? []).filter { $0.mode != .off && !$0.name.isEmpty } }

    /// What the reviewer is told, or nil when there's nothing to say.
    var reviewInstructions: String? {
        var parts: [String] = []
        if let profile { parts.append(profile.instructions) }
        if let instructions = instructions?.nonEmpty { parts.append("The team's instructions for reviews of this repo:\n\(instructions)") }
        if let tone = tone?.nonEmpty { parts.append("Tone of your comments: \(tone)") }
        if let ignore = ignore?.filter({ !$0.isEmpty }), !ignore.isEmpty {
            parts.append("Don't review files matching these globs (don't read them for findings, and raise nothing on them): \(ignore.map { "`\($0)`" }.joined(separator: ", ")).")
        }
        let paths = (pathInstructions ?? []).filter { !$0.path.isEmpty && !$0.instructions.isEmpty }
        if !paths.isEmpty {
            parts.append("For files matching these globs, also:\n" + paths.map { "- `\($0.path)`: \($0.instructions.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n"))
        }
        let checks = activeChecks
        if !checks.isEmpty {
            parts.append("""
                Judge the PR against each of these checks, and give a result for every one in the JSON's `checks`: \
                {"name": "<the check's name>", "result": "pass" | "fail" | "inconclusive", "reason": "<a sentence: why, and what would fix it>"}.
                \(checks.map { "- \($0.name): \($0.instructions.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n"))
                """)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    static let path = ".gannin/review.json"

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// A repo's own file: one config.
    static func read(_ text: String) -> ReviewConfig? {
        try? decoder.decode(ReviewConfig.self, from: Data(text.utf8))
    }

    var json: String {
        (try? Self.encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) + "\n" } ?? ""
    }
}

/// The harness's file: defaults for the project's repos and a section per
/// repo (`owner/name`). Sections are a list, not an object keyed by repo, as
/// the snake case coding would rewrite keys with capitals or underscores.
struct HarnessReviewConfig: Codable, Hashable {
    struct Section: Codable, Hashable {
        var repo: String
        var config: ReviewConfig
    }

    var defaults: ReviewConfig?
    var repos: [Section]?

    static func read(_ text: String?) -> HarnessReviewConfig {
        text.flatMap { try? ReviewConfig.decoder.decode(HarnessReviewConfig.self, from: Data($0.utf8)) } ?? HarnessReviewConfig()
    }

    func config(for repo: String) -> ReviewConfig? {
        repos?.first { $0.repo.caseInsensitiveCompare(repo) == .orderedSame }?.config
    }

    /// With the repo's section replaced, or removed when `config` is empty.
    func setting(_ config: ReviewConfig?, for repo: String) -> HarnessReviewConfig {
        var copy = self
        var sections = (repos ?? []).filter { $0.repo.caseInsensitiveCompare(repo) != .orderedSame }
        if let config, !config.isEmpty { sections.append(Section(repo: repo, config: config)) }
        copy.repos = sections.isEmpty ? nil : sections.sorted { $0.repo < $1.repo }
        return copy
    }

    var json: String {
        (try? ReviewConfig.encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) + "\n" } ?? ""
    }
}

extension ReviewConfig {
    /// The places a repo's config comes from, in the order they're laid on.
    struct Layers {
        var defaults: ReviewConfig?
        var harness: ReviewConfig?
        var repo: ReviewConfig?

        var resolved: ReviewConfig {
            [defaults, harness, repo].compactMap { $0 }.reduce(ReviewConfig()) { $0.overlaid(with: $1) }
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Glob matching for paths: `**` any folders, `*` within a name, `?` one
/// character; a pattern ending `/` is a folder and everything in it.
enum Glob {
    static func matches(_ pattern: String, _ path: String) -> Bool {
        var pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        if pattern.hasSuffix("/") { pattern += "**" }
        // A bare name matches anywhere, as .gitignore does.
        if !pattern.contains("/") { pattern = "**/" + pattern }
        var regex = "^"
        var characters = Array(pattern)[...]
        while let character = characters.popFirst() {
            switch character {
            case "*":
                if characters.first == "*" {
                    characters.removeFirst()
                    if characters.first == "/" {
                        characters.removeFirst()
                        regex += "(?:.*/)?"
                    } else {
                        regex += ".*"
                    }
                } else {
                    regex += "[^/]*"
                }
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}

// MARK: - Reading it

extension GitHubAPI {
    /// A file on a repo's default branch, or nil when it isn't there.
    func repoFile(repo: String, path: String) async throws -> String? {
        struct Contents: Decodable { let content: String?; let encoding: String? }
        let contents: Contents
        do {
            contents = try await rest("repos/\(repo)/contents/\(path)")
        } catch {
            return nil
        }
        guard let content = contents.content, contents.encoding == "base64",
              let data = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension SessionStore {
    /// A repo's review config: the harness's defaults and section for it,
    /// with the repo's own file on its default branch over them.
    func reviewConfig(org: String, harness setup: HarnessConfig, repo: String) async -> ReviewConfig.Layers {
        let file = harnessStore.index(for: org, setup)?.dataFiles?.first { $0.path == ReviewConfig.path }
        let team = HarnessReviewConfig.read(file?.text)
        var layers = ReviewConfig.Layers(defaults: team.defaults, harness: team.config(for: repo))
        if let api = api(), let text = try? await chargingTo(.details, { try await api.repoFile(repo: repo, path: ReviewConfig.path) }) {
            layers.repo = ReviewConfig.read(text)
        }
        return layers
    }
}
