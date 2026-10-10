import SwiftUI

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 22

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Overlapping avatars for a small group of people.
struct AvatarStack: View {
    let people: [Person]
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: -size / 3) {
            ForEach(people.prefix(4)) { person in
                Avatar(url: person.avatarUrl, size: size)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    .help(person.displayName)
            }
        }
    }
}

struct CountBadge: View {
    let count: Int
    let systemImage: String
    let help: String
    var tint: Color = .secondary

    var body: some View {
        Label("\(count)", systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.monospacedDigit())
            .foregroundStyle(count == 0 ? Color.secondary.opacity(0.5) : tint)
            .help(help)
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var systemImage: String? = nil

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
            } else {
                Text(text)
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

struct LabelChip: View {
    let label: IssueLabel

    var body: some View {
        Pill(text: label.name, color: Color(hex: label.color) ?? .secondary)
    }
}

extension PullRequest {
    /// Someone other than the author has left a review, of any kind: a
    /// comment-only review doesn't move `reviewDecision` or `review`, so
    /// without this a PR someone has already looked at reads the same as
    /// one nobody has touched. Automation accounts (coderabbitai and the
    /// like) don't count, so their reviews don't read as a teammate's.
    var hasBeenReviewed: Bool {
        humanReviewStates.keys.contains { $0 != author?.login }
    }

    var statusText: String {
        if isMerged { return "Merged" }
        if state == "CLOSED" { return "Closed" }
        if isDraft { return "Draft" }
        switch review {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .reviewRequired, nil: return hasBeenReviewed ? "Commented" : "In review"
        }
    }

    var statusColor: Color {
        if isMerged { return .purple }
        if state == "CLOSED" { return .red }
        if isDraft { return .gray }
        switch review {
        case .approved: return .green
        case .changesRequested: return .orange
        case .reviewRequired, nil: return .blue
        }
    }
}

extension LinkedItem {
    var stateColor: Color {
        switch state {
        case "MERGED": .purple
        case "CLOSED": .red
        default: .green
        }
    }
}

/// A PR-like state used to tint a list's linked-PR badge, shared by the
/// workload world's `LinkedItem` and the issue history's
/// `IssueLinkedPullRequest`.
protocol PullRequestStateProviding {
    var isMerged: Bool { get }
    var isOpenState: Bool { get }
}

extension LinkedItem: PullRequestStateProviding {
    var isMerged: Bool { state == "MERGED" }
    var isOpenState: Bool { state == "OPEN" }
}

extension IssueLinkedPullRequest: PullRequestStateProviding {
    var isMerged: Bool { mergedAt != nil }
    var isOpenState: Bool { state == "OPEN" }

    var statusText: String { isMerged ? "Merged" : state.capitalized }

    var statusColor: Color {
        if isMerged { return .purple }
        if state == "CLOSED" { return .red }
        return .green
    }
}

extension Array where Element: PullRequestStateProviding {
    /// Purple once one has merged, green while one's still open, grey when
    /// every one is closed unmerged: a list's badge colour without opening it.
    var linkedPullRequestsTint: Color {
        if contains(where: \.isMerged) { return .purple }
        if contains(where: \.isOpenState) { return .green }
        return .secondary
    }
}

/// A list row's linked- or mentioned-PR count, tinted and captioned by
/// whether any of them have merged.
struct LinkedPullRequestsBadge: View {
    let count: Int
    let tint: Color
    let anyMerged: Bool
    var systemImage = "arrow.triangle.pull"
    var label = "Linked pull requests"

    var body: some View {
        Label("\(count)", systemImage: systemImage)
            .foregroundStyle(tint)
            .help(anyMerged ? "\(label), some merged" : label)
    }
}

/// One linked or mentioned PR in an issue's drawer or window: its number,
/// status and, when it has any, its most recent commit or review.
struct LinkedPullRequestRow: View {
    let pr: IssueLinkedPullRequest
    var systemImage = "arrow.triangle.pull"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(pr.statusColor)
            Link(pr.repo.map { "\($0)#\(pr.number)" } ?? "#\(pr.number)", destination: pr.url)
            Pill(text: pr.statusText, color: pr.statusColor)
            Spacer()
            if let last = pr.activityAt.max() {
                Text("active").font(.caption).foregroundStyle(.secondary)
                RelativeDate(date: last).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("opened").font(.caption).foregroundStyle(.secondary)
                RelativeDate(date: pr.createdAt).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension Color {
    /// Parses GitHub's six-digit hex label colours.
    init?(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

struct RelativeDate: View {
    let date: Date

    var body: some View {
        Text(date, format: .relative(presentation: .named))
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }
}

/// "Updating" with a spinner for a section header while the org's metrics
/// sync, such as after the window changes and older weeks are backfilled.
struct MetricsSyncIndicator: View {
    @Environment(MetricsStore.self) private var store
    let org: String

    var body: some View {
        if store.syncing.contains(org) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating")
                    .font(.callout.weight(.regular))
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
        }
    }
}

extension View {
    /// Fades content showing numbers that are about to change.
    func updating(_ isUpdating: Bool) -> some View {
        opacity(isUpdating ? 0.5 : 1)
            .animation(.easeOut(duration: 0.2), value: isUpdating)
    }
}

/// One-line notice with the full text in a tooltip and an optional retry.
struct Banner: View {
    let message: String
    let systemImage: String
    let tint: Color
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(message)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let retry {
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .help(message)
    }
}
