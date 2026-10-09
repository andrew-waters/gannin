import SwiftUI

// MARK: - Can it merge?

/// Whether a reviewed PR can merge and what's in the way, in the spirit of
/// CodeRabbit's Overview: one sentence for the header, and the items behind
/// it in tiers (blocking, to fix, waiting, not blocking), from GitHub's
/// state (conflicts, draft, review decision, checks, open threads) and the
/// reviewer's findings not dismissed.
struct ReviewReadiness {
    enum Tier: Int, CaseIterable, Identifiable {
        case blocking, fix, waiting, minor

        var id: Self { self }

        var title: String {
            switch self {
            case .blocking: "Blocking the merge"
            case .fix: "Fix before merging"
            case .waiting: "Waiting on"
            case .minor: "Not blocking"
            }
        }

        var symbol: String {
            switch self {
            case .blocking: "xmark.octagon.fill"
            case .fix: "exclamationmark.triangle.fill"
            case .waiting: "clock.fill"
            case .minor: "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .blocking: ChartPalette.critical
            case .fix: .orange
            case .waiting: ChartPalette.blue
            case .minor: .secondary
            }
        }
    }

    /// What clicking an item does.
    enum Action: Hashable {
        /// A changed file's diff.
        case file(String)
        /// Findings not on a changed file.
        case general
        case url(URL)
    }

    struct Item: Identifiable {
        let id: String
        let tier: Tier
        let text: String
        var detail: String?
        var category: ReviewCategory?
        var action: Action?
    }

    var items: [Item] = []
    var sentence: String
    var color: Color
    var symbol: String

    func items(_ tier: Tier) -> [Item] { items.filter { $0.tier == tier } }

    /// `config` gives the checks' modes: a failed error blocks, a failed
    /// warning is to fix.
    /// `isStale`: commits pushed since the review, not looked at yet.
    init(status: SessionPullRequest?, pullRequest: ReviewedPullRequest?, review: SessionTranscript.ReviewResult?, draft: ReviewDraft, isReviewing: Bool, config: ReviewConfig? = nil, isStale: Bool = false) {
        if let state = pullRequest?.state, state != "open" {
            sentence = state == "merged" ? "Merged" : "Closed"
            color = state == "merged" ? .purple : .secondary
            symbol = state == "merged" ? "arrow.triangle.merge" : "xmark.circle"
            return
        }
        var blocking: [String] = []
        var fix: [String] = []
        var waiting: [String] = []
        var items: [Item] = []
        let files = Set(pullRequest?.files.map(\.path) ?? [])

        if let status {
            let url = status.url
            if status.mergeable == "CONFLICTING" {
                blocking.append("conflicts with the base branch")
                items.append(Item(id: "conflicts", tier: .blocking, text: "Conflicts with the base branch", detail: "Resolve them on the branch, or on GitHub", action: .url(url.appending(path: "conflicts"))))
            }
            if status.isDraft {
                blocking.append("it's still a draft")
                items.append(Item(id: "draft", tier: .blocking, text: "Still a draft", detail: "Mark it ready for review on GitHub", action: .url(url)))
            }
            if status.reviewDecision == "CHANGES_REQUESTED" {
                let who = Set(status.feedback.filter { $0.verdict != nil }.map(\.author)).sorted()
                blocking.append("changes were requested")
                items.append(Item(id: "changes", tier: .blocking, text: "Changes requested", detail: who.isEmpty ? nil : "By " + who.map { "@\($0)" }.joined(separator: ", "), action: .url(url)))
            }
            for check in status.failed {
                items.append(Item(id: "check:\(check.id)", tier: .fix, text: "\(check.name) is failing", action: check.url.map(Action.url)))
            }
            if !status.failed.isEmpty {
                fix.append(status.failed.count == 1 ? "a check is failing" : "\(status.failed.count) checks are failing")
            }
            if !status.pending.isEmpty {
                waiting.append(status.pending.count == 1 ? "its check passes" : "its checks pass")
                items.append(Item(id: "pending", tier: .waiting, text: status.pending.count == 1 ? "A check is running" : "\(status.pending.count) checks are running", detail: status.pending.map(\.name).joined(separator: ", "), action: .url(url.appending(path: "checks"))))
            }
            if status.reviewDecision == "REVIEW_REQUIRED" {
                waiting.append("it's approved")
                items.append(Item(id: "approval", tier: .waiting, text: "Waiting for an approving review", action: .url(url)))
            }
            if status.mergeable == "UNKNOWN" {
                waiting.append("GitHub has checked it merges cleanly")
                items.append(Item(id: "mergeable", tier: .waiting, text: "GitHub is still checking whether it merges cleanly"))
            }
            for thread in status.feedback where thread.location != nil {
                let last = thread.comments.last
                items.append(Item(id: "thread:\(thread.id)", tier: .minor, text: "Open thread from @\(thread.author)", detail: [thread.location, last.map { String($0.body.prefix(120)) }].compactMap { $0 }.joined(separator: ": "), action: last.map { .url($0.url) }))
            }
        }
        if isStale && !isReviewing {
            waiting.append("the reviewer has looked at the new commits")
            items.append(Item(id: "stale", tier: .waiting, text: "New commits since this review", detail: "Watched reviews look again once it's quiet; Review Again does it now"))
        }
        if isReviewing {
            waiting.append("the reviewer finishes")
            items.append(Item(id: "reviewing", tier: .waiting, text: "The reviewer is still looking"))
        }

        let findings = (review?.findings ?? []).filter { draft.decisions[$0.key] != .dismissed }
        var counts: [ReviewSeverity: Int] = [:]
        for finding in findings {
            let severity = ReviewSeverity(finding.severity) ?? .minor
            counts[severity, default: 0] += 1
            let tier: Tier = switch severity {
            case .blocker: .blocking
            case .major: .fix
            case .minor, .nit: .minor
            }
            var text = finding.comment
            if case .edited(let edited) = draft.decisions[finding.key] { text = edited }
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
            items.append(Item(
                id: "finding:\(finding.key)", tier: tier, text: String(firstLine.prefix(160)),
                detail: "\(severity.title) · " + (finding.line.map { "\(finding.path):\($0)" } ?? finding.path),
                category: ReviewCategory(finding.category),
                action: files.contains(finding.path) ? .file(finding.path) : .general
            ))
        }
        if let blockers = counts[.blocker] { blocking.append(blockers == 1 ? "a blocker finding" : "\(blockers) blocker findings") }
        if let majors = counts[.major] { fix.append(majors == 1 ? "a major finding" : "\(majors) major findings") }
        var failedErrors = 0
        var failedWarnings = 0
        for check in review?.checks ?? [] {
            let mode = config?.mode(of: check.name) ?? .warning
            guard mode != .off else { continue }
            switch check.result.lowercased() {
            case "fail":
                items.append(Item(id: "check-config:\(check.name)", tier: mode == .error ? .blocking : .fix, text: "Fails the \(check.name) check", detail: check.reason))
                if mode == .error { failedErrors += 1 } else { failedWarnings += 1 }
            case "inconclusive":
                items.append(Item(id: "check-config:\(check.name)", tier: .minor, text: "Couldn't tell whether it passes the \(check.name) check", detail: check.reason))
            default:
                break
            }
        }
        if failedErrors > 0 { blocking.append(failedErrors == 1 ? "it fails a check" : "it fails \(failedErrors) checks") }
        if failedWarnings > 0 { fix.append(failedWarnings == 1 ? "it fails a check" : "it fails \(failedWarnings) checks") }
        let minor = items.filter { $0.tier == .minor }.count

        self.items = items
        if !blocking.isEmpty {
            sentence = "Can't merge: " + Self.list(blocking)
            color = ChartPalette.critical
            symbol = Tier.blocking.symbol
        } else if !fix.isEmpty {
            sentence = "Not ready: " + Self.list(fix)
            color = .orange
            symbol = Tier.fix.symbol
        } else if status == nil && pullRequest == nil {
            sentence = "Checking whether it can merge"
            color = .secondary
            symbol = "hourglass"
        } else if !waiting.isEmpty {
            sentence = "Ready once " + Self.list(waiting)
            color = ChartPalette.blue
            symbol = Tier.waiting.symbol
        } else {
            sentence = minor == 0 ? "Ready to merge" : "Ready to merge, with \(minor) minor point\(minor == 1 ? "" : "s")"
            color = ChartPalette.good
            symbol = "checkmark.circle.fill"
        }
    }

    /// "a, b and c".
    static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
}

// MARK: - The Overview

/// A review's first page: what the PR does and how to read it, whether it
/// can merge and what needs attention, its description, and beside them
/// the PR's own conversation with a box for asking the reviewer more.
struct ReviewOverview: View {
    @Environment(DetailStore.self) private var details
    let session: CodeSession
    let reference: PullRequestReference
    let pullRequest: ReviewedPullRequest
    let review: SessionTranscript.ReviewResult?
    let readiness: ReviewReadiness
    let status: SessionPullRequest?
    let canAsk: Bool
    /// Opens what an item or a walkthrough file points at.
    let open: (ReviewReadiness.Action) -> Void
    /// Sends a question to the reviewer; true once it's sent.
    let ask: (String) -> Bool
    @State private var question = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heading
                    attention
                    configChecks
                    walkthrough
                    flow
                    description
                }
                .padding(20)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            rail
                .frame(width: 320)
        }
    }

    // MARK: Main column

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let headline = review?.headline {
                Text(headline)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Label(readiness.sentence, systemImage: readiness.symbol)
                    .foregroundStyle(readiness.color)
                    .font(.headline)
                if let effort = review?.effort {
                    EffortMeter(effort: effort)
                }
            }
            if let review {
                MarkdownText(source: review.summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("The summary, walkthrough and findings show here once the reviewer has finished.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var attention: some View {
        let tiers = ReviewReadiness.Tier.allCases.filter { !readiness.items($0).isEmpty }
        if !tiers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Needs attention").font(.title3.weight(.semibold))
                ForEach(tiers) { tier in
                    VStack(alignment: .leading, spacing: 6) {
                        Label(tier.title, systemImage: tier.symbol)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(tier.color)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(readiness.items(tier)) { item in
                                attentionRow(item)
                                if item.id != readiness.items(tier).last?.id { Divider() }
                            }
                        }
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func attentionRow(_ item: ReviewReadiness.Item) -> some View {
        Button {
            if let action = item.action { open(action) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(item.tier.color).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).fixedSize(horizontal: false, vertical: true)
                    if let detail = item.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if let category = item.category {
                    CategoryChip(category: category)
                }
                if item.action != nil {
                    Image(systemName: actionSymbol(item.action)).foregroundStyle(.secondary).font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.action == nil)
    }

    private func actionSymbol(_ action: ReviewReadiness.Action?) -> String {
        if case .url = action { return "arrow.up.right.square" }
        return "chevron.right"
    }

    /// Every check the review config holds the PR to, passed or not.
    @ViewBuilder
    private var configChecks: some View {
        if let results = review?.checks, !results.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Checks").font(.title3.weight(.semibold))
                ForEach(results, id: \.self) { check in
                    let mode = session.reviewConfig?.mode(of: check.name) ?? .warning
                    let (symbol, color): (String, Color) = switch check.result.lowercased() {
                    case "pass": ("checkmark.circle.fill", ChartPalette.good)
                    case "fail": ("xmark.circle.fill", mode == .error ? ChartPalette.critical : .orange)
                    default: ("questionmark.circle.fill", .secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol).foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(check.name).fontWeight(.medium)
                                Text(mode.title).font(.caption).foregroundStyle(.secondary)
                            }
                            if let reason = check.reason {
                                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var walkthrough: some View {
        if let areas = review?.walkthrough, !areas.isEmpty {
            let changed = Set(pullRequest.files.map(\.path))
            VStack(alignment: .leading, spacing: 12) {
                Text("Walkthrough").font(.title3.weight(.semibold))
                Text("The change in the order to read it. The file list follows it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(Array(areas.enumerated()), id: \.offset) { index, area in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        AreaNumber(number: index + 1)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(area.title).fontWeight(.semibold)
                            if let summary = area.summary {
                                Text(summary).fixedSize(horizontal: false, vertical: true)
                            }
                            FlowLayoutFiles(files: area.files.filter(changed.contains)) { open(.file($0)) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var flow: some View {
        if let steps = review?.flow, !steps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("What happens").font(.title3.weight(.semibold))
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Description").font(.title3.weight(.semibold))
                if let author = pullRequest.author {
                    Text("by @\(author)").foregroundStyle(.secondary)
                }
            }
            if pullRequest.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description").foregroundStyle(.tertiary)
            } else {
                MarkdownText(source: pullRequest.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Conversation").font(.headline)
                    Text("Comments on the PR itself. Comments on lines are on the code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let reviews = status?.feedback.filter { $0.location == nil } ?? []
                    ForEach(reviews) { item in
                        reviewCard(item)
                    }
                    if let detail = details.detail(for: reference.id) {
                        if detail.commentCount > detail.recentComments.count {
                            Link("\(detail.commentCount - detail.recentComments.count) earlier comments on GitHub", destination: reference.url)
                                .font(.callout)
                        }
                        ForEach(detail.recentComments) { comment in
                            CommentView(comment: comment)
                            Divider()
                        }
                        if detail.recentComments.isEmpty && reviews.isEmpty {
                            Text("No comments yet").foregroundStyle(.tertiary)
                        }
                    } else if let error = details.errors[reference.id] {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            askBox
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func reviewCard(_ item: SessionPullRequest.Feedback) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("@\(item.author)").fontWeight(.medium)
                if let verdict = item.verdict {
                    Text(verdict).font(.caption).foregroundStyle(.orange)
                } else {
                    Text("reviewed").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = item.comments.last?.url {
                    Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                        .help("Open on GitHub")
                }
            }
            ForEach(Array(item.comments.enumerated()), id: \.offset) { _, comment in
                MarkdownText(source: comment.body)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var askBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask the reviewer").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 6) {
                TextField(canAsk ? "Why is this a blocker?" : "Resume the review to ask it more", text: $question, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!canAsk)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!canAsk || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send to the reviewer; its answer is in the conversation")
            }
        }
        .padding(12)
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, ask(text) else { return }
        question = ""
    }
}

// MARK: - Small pieces

/// A walkthrough area's number, as the file list's sections show it too.
struct AreaNumber: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.caption.weight(.bold).monospacedDigit())
            .frame(width: 20, height: 20)
            .background(Color.accentColor.opacity(0.18), in: Circle())
            .foregroundStyle(Color.accentColor)
    }
}

/// How much work reviewing it by hand is, as five pips.
struct EffortMeter: View {
    let effort: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("Effort").foregroundStyle(.secondary)
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { pip in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(pip <= effort ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 8, height: 10)
                }
            }
        }
        .font(.callout)
        .help("Review effort \(effort) of 5, as the reviewer judged how much work reading it by hand is")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Review effort \(effort) of 5")
    }
}

/// A finding's category.
struct CategoryChip: View {
    let category: ReviewCategory

    var body: some View {
        Label(category.shortTitle, systemImage: category.systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .help(category.title)
            .fixedSize()
    }
}

/// An area's files as buttons, wrapping onto as many lines as they need.
private struct FlowLayoutFiles: View {
    let files: [String]
    let open: (String) -> Void

    var body: some View {
        WrappingStack(spacing: 6) {
            ForEach(files, id: \.self) { path in
                Button {
                    open(path)
                } label: {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help(path)
            }
        }
    }
}

/// Lays subviews out in rows, wrapping when the width runs out.
private struct WrappingStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
