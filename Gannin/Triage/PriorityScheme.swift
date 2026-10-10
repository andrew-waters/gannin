import Foundation

// Triage: a project's loose priority buckets (Now, Next, Later, or however
// the team marks it), read from GitHub the way the team keeps them: a label
// per bucket, or an option of a single-select field on one board.
//
// The scheme is a project team file, `.gannin/triage.json`. An issue's
// bucket is always what GitHub says; Gannin keeps no priority of its own.

/// One of a scheme's buckets, in the scheme's order (most urgent first).
struct PriorityBucket: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// 0-7, a categorical colour slot as investment categories have; follows
    /// the bucket, so reordering never repaints it.
    var slot: Int
    /// Its label, or its option on the tracked board field. Empty never
    /// matches, so a half-made bucket doesn't claim every issue.
    var githubValue: String

    init(id: UUID = UUID(), name: String, slot: Int, githubValue: String) {
        self.id = id
        self.name = name
        self.slot = slot
        self.githubValue = githubValue
    }

    /// Tolerates a bucket written by hand with only some of its fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        slot = try container.decodeIfPresent(Int.self, forKey: .slot) ?? 0
        githubValue = try container.decodeIfPresent(String.self, forKey: .githubValue) ?? name
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, slot, githubValue
    }
}

/// Where a project keeps its issues' buckets on GitHub.
enum PriorityTracking: Codable, Hashable {
    /// A label per bucket.
    case labels
    /// A single-select field on one board, an option per bucket.
    case projectField(projectNumber: Int, projectTitle: String, field: String)

    var summary: String {
        switch self {
        case .labels: "GitHub labels"
        case .projectField(_, let project, let field): "\(field) on \(project)"
        }
    }

    /// What a bucket's GitHub value is called here.
    var valueName: String {
        switch self {
        case .labels: "Label"
        case .projectField(_, _, let field): "\(field) option"
        }
    }
}

/// Where an issue sits in a scheme.
enum PriorityReading: Hashable {
    /// No bucket's label or option.
    case untriaged
    case bucket(PriorityBucket)
    /// Labels of more than one bucket, in the scheme's order. Only labels
    /// can conflict: a single-select field holds one option.
    case conflicting([PriorityBucket])

    var assigned: PriorityBucket? {
        if case .bucket(let bucket) = self { return bucket }
        return nil
    }

    var isUntriaged: Bool { self == .untriaged }
    var isConflicting: Bool {
        if case .conflicting = self { return true }
        return false
    }

    /// Wants a decision in a pass: no bucket, or more than one.
    var needsTriage: Bool { assigned == nil }
}

/// A project's priority scheme, as the team keeps it in `.gannin/triage.json`.
struct PriorityScheme: Codable, Hashable {
    var buckets: [PriorityBucket]
    var tracking: PriorityTracking
    /// The day the last pass's changes were written, at local midnight, so
    /// the next pass knows what's changed since. Nil before the first.
    var lastPass: Date?

    init(buckets: [PriorityBucket], tracking: PriorityTracking = .labels, lastPass: Date? = nil) {
        self.buckets = buckets
        self.tracking = tracking
        self.lastPass = lastPass
    }

    /// Tolerates a file missing parts: no buckets, labels, no pass yet. A
    /// tracking it can't read is labels, so the buckets still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try container.decodeIfPresent([PriorityBucket].self, forKey: .buckets) ?? []
        tracking = (try? container.decodeIfPresent(PriorityTracking.self, forKey: .tracking)) ?? .labels
        lastPass = try? container.decodeIfPresent(Date.self, forKey: .lastPass)
    }

    private enum CodingKeys: String, CodingKey {
        case buckets, tracking, lastPass
    }

    func bucket(id: UUID) -> PriorityBucket? {
        buckets.first { $0.id == id }
    }

    /// The buckets' GitHub values, for removing the others when one is set.
    var githubValues: [String] { buckets.map(\.githubValue).filter { !$0.isEmpty } }

    /// An issue's bucket, as GitHub has it: the buckets whose label it has,
    /// or whose option it has on the tracked field, matched ignoring case.
    func reading(_ issue: IssueRecord) -> PriorityReading {
        let matched: [PriorityBucket]
        switch tracking {
        case .labels:
            matched = buckets.filter { bucket in
                !bucket.githubValue.isEmpty && issue.labels.contains { $0.caseInsensitiveCompare(bucket.githubValue) == .orderedSame }
            }
        case .projectField(let number, _, let field):
            let current = issue.fields(onProject: number)?.values.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value.display
            matched = current.flatMap { current in
                buckets.first { !$0.githubValue.isEmpty && $0.githubValue.caseInsensitiveCompare(current) == .orderedSame }
            }.map { [$0] } ?? []
        }
        switch matched.count {
        case 0: return .untriaged
        case 1: return .bucket(matched[0])
        default: return .conflicting(matched)
        }
    }
}
