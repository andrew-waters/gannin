import SwiftUI

/// The finished PR reviews of an org, newest first, to look through and
/// remove in bulk. Other kinds of session aren't listed: finished issue
/// sessions are forgotten when they finish, and Ask and planning sessions
/// have their own lists. A search narrows them to those matching every word typed
/// (`SessionSearch`). Removing forgets a review as the sidebar's Remove from
/// History does: its record already committed to a harness stays there.
struct ReviewHistorySheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    let org: String
    @State private var search = ""
    @State private var selection: Set<UUID> = []
    @State private var confirming = false

    /// Finished reviews, most recently finished first. Read from the store
    /// so a review removed elsewhere drops out.
    private var finished: [CodeSession] {
        SessionSidebarGroups(sessions.sessions(for: org), awaitsAuthor: { _ in false }).finishedReviews
    }

    var body: some View {
        let words = SessionSearch.words(search)
        let shown = finished.filter { SessionSearch.matches($0, words: words, pullRequests: sessions.pullRequestInfo[$0.id] ?? []) }
        // Selections that a search or a removal has hidden aren't removed.
        let chosen = shown.filter { selection.contains($0.id) }
        VStack(spacing: 0) {
            HStack {
                FilterSearchField(text: $search, prompt: "Title, repo or PR", fills: true)
                    .onEscape { search = "" }
            }
            .controlSize(.small)
            .font(.callout)
            .padding(12)
            Divider()
            if shown.isEmpty {
                ContentUnavailableView(finished.isEmpty ? "No finished reviews" : "No matches", systemImage: "archivebox")
            } else {
                List(shown, selection: $selection) { session in
                    row(session)
                }
            }
            Divider()
            HStack {
                Text(chosen.isEmpty ? "\(shown.count) finished" : "\(chosen.count) of \(shown.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select All") { selection = Set(shown.map(\.id)) }
                    .disabled(shown.isEmpty || chosen.count == shown.count)
                Button("Remove Selected…", role: .destructive) { confirming = true }
                    .disabled(chosen.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 420)
        .confirmationDialog("Remove \(chosen.count) finished \(chosen.count == 1 ? "review" : "reviews")?", isPresented: $confirming) {
            Button("Remove from History", role: .destructive) {
                for session in chosen { sessions.remove(session.id) }
                selection.subtract(chosen.map(\.id))
            }
        } message: {
            Text("Gannin forgets them. A review's findings already committed to a harness stay there, and the pull requests are untouched.")
        }
    }

    private func row(_ session: CodeSession) -> some View {
        HStack {
            Text(session.title).lineLimit(1)
            Spacer()
            if let pullRequest = session.reviewOf {
                Text("\(pullRequest.repo)#\(pullRequest.number)").font(.caption).foregroundStyle(.secondary)
            }
            if let archived = session.archivedAt {
                Text(archived.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
