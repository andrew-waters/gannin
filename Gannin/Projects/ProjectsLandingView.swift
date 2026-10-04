import SwiftUI

/// The Boards page before a board is picked, in place of a repo's Projects
/// tab on GitHub: the org's boards (or, for a project that takes its boards
/// from a repo, those linked to it), open or closed, with a search. New
/// Board makes one, blank or a copy; Link Board shows another of the org's
/// on the repo; each board can be unlinked, closed or reopened. Every write
/// is confirmed first.
struct ProjectsLandingView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(OrgConfigStore.self) private var configs
    @Environment(AuthStore.self) private var auth
    let org: String
    let onOpen: (Int) -> Void

    @State private var search = ""
    @State private var showsClosed = false
    @State private var creating = false
    /// A write waiting to be confirmed.
    @State private var pending: BoardChange?
    @State private var working = false
    @State private var error: String?

    enum BoardChange: Identifiable {
        case link(OrgProject, repo: String)
        case unlink(OrgProject, repo: String)
        case close(OrgProject)
        case reopen(OrgProject)

        var id: String {
            switch self {
            case .link(let board, _): "link\(board.id)"
            case .unlink(let board, _): "unlink\(board.id)"
            case .close(let board): "close\(board.id)"
            case .reopen(let board): "reopen\(board.id)"
            }
        }

        var title: String {
            switch self {
            case .link(let board, let repo): "Link \(board.title) to \(repo)?"
            case .unlink(let board, let repo): "Unlink \(board.title) from \(repo)?"
            case .close(let board): "Close \(board.title)?"
            case .reopen(let board): "Reopen \(board.title)?"
            }
        }

        var action: String {
            switch self {
            case .link: "Link Board"
            case .unlink: "Unlink Board"
            case .close: "Close Board"
            case .reopen: "Reopen Board"
            }
        }

        var message: String {
            switch self {
            case .link(_, let repo): "It shows on \(repo)'s Projects tab on GitHub."
            case .unlink(_, let repo): "It comes off \(repo)'s Projects tab. The board and its items are untouched."
            case .close: "A closed board is read-only on GitHub and leaves Gannin's lists. It can be reopened."
            case .reopen: "It's open again on GitHub and in Gannin's lists."
            }
        }
    }

    var body: some View {
        let repo = configs.config(for: org).boardsRepo
        let all = store.allBoards(org: org, repo: repo)
        let open = all.filter { !$0.closed }
        let closed = all.filter(\.closed)
        let boards = (showsClosed ? closed : open).filter(matches)
        VStack(spacing: 0) {
            bar(open: open.count, closed: closed.count)
            Divider()
            List {
                if boards.isEmpty {
                    empty(repo: repo, isSearching: !search.isEmpty)
                }
                ForEach(boards) { board in
                    row(board, repo: repo)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
        }
        .toolbar {
            if let repo {
                ToolbarItem {
                    linkMenu(repo: repo, linked: Set(all.map(\.id)))
                }
            }
            ToolbarItem {
                Button { creating = true } label: { Label("New Board", systemImage: "plus") }
                    .help("Make a board in \(org), blank or a copy of another")
            }
        }
        .sheet(isPresented: $creating) {
            NewBoardSheet(org: org, repo: repo) { board in onOpen(board.number) }
        }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { change in
            Button(change.action, role: change.isDestructive ? .destructive : nil) { apply(change) }
        } message: { change in
            Text(change.message)
        }
        .task(id: org) { await store.loadBoards(org: org) }
        .task(id: repo) { if let repo { await store.loadRepoBoards(org: org, repo: repo) } }
    }

    /// Search, then Open or Closed with their counts.
    private func bar(open: Int, closed: Int) -> some View {
        HStack(spacing: 8) {
            FilterSearchField(text: $search, prompt: "Search boards")
            Picker("Boards", selection: $showsClosed) {
                Text("Open \(open)").tag(false)
                Text("Closed \(closed)").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
            if working { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func row(_ board: OrgProject, repo: String?) -> some View {
        Button { onOpen(board.number) } label: {
            HStack {
                Image(systemName: "rectangle.split.3x1").foregroundStyle(.secondary)
                Text(board.title)
                Spacer()
                Text("#\(String(board.number))").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { onOpen(board.number) }
            if let url = url(board) {
                Link("Open on GitHub", destination: url)
            }
            Divider()
            if let repo {
                Button("Unlink from \(repo)") { pending = .unlink(board, repo: repo) }
            }
            if board.closed {
                Button("Reopen Board") { pending = .reopen(board) }
            } else {
                Button("Close Board") { pending = .close(board) }
            }
        }
    }

    @ViewBuilder
    private func empty(repo: String?, isSearching: Bool) -> some View {
        if isSearching {
            Text("No boards match.").foregroundStyle(.secondary)
        } else if showsClosed {
            Text("No closed boards.").foregroundStyle(.secondary)
        } else if let repo {
            Text("No boards are linked to \(repo) yet. Make one with New Board, or link one of \(org)'s with Link Board.")
                .foregroundStyle(.secondary)
        } else {
            Text("No open boards, or Gannin can't see them yet. Reading boards needs project access.")
                .foregroundStyle(.secondary)
        }
    }

    /// The org's open boards not linked to the repo yet.
    private func linkMenu(repo: String, linked: Set<String>) -> some View {
        let candidates = store.boards(org: org, repo: nil).filter { !linked.contains($0.id) }
        return Menu {
            if candidates.isEmpty {
                Text("Every open board is linked")
            }
            ForEach(candidates) { board in
                Button(board.title) { pending = .link(board, repo: repo) }
            }
        } label: {
            Label("Link Board", systemImage: "link")
        }
        .help("Show one of \(org)'s boards on \(repo)")
    }

    private func matches(_ board: OrgProject) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || board.title.localizedCaseInsensitiveContains(query) || "#\(board.number)".contains(query)
    }

    private func url(_ board: OrgProject) -> URL? {
        let kind = GitHubAccounts.isUser(org) ? "users" : "orgs"
        return URL(string: "https://github.com/\(kind)/\(org)/projects/\(board.number)")
    }

    private func apply(_ change: BoardChange) {
        guard let api = auth.api else { return }
        working = true
        error = nil
        Task {
            do {
                switch change {
                case .link(let board, let repo):
                    try await api.linkBoard(board.id, repositoryID: try await api.repositoryID(repo))
                case .unlink(let board, let repo):
                    try await api.unlinkBoard(board.id, repositoryID: try await api.repositoryID(repo))
                case .close(let board):
                    try await api.setBoardClosed(board.id, closed: true)
                case .reopen(let board):
                    try await api.setBoardClosed(board.id, closed: false)
                }
            } catch {
                self.error = error.localizedDescription
            }
            await store.loadBoards(org: org)
            if let repo = configs.config(for: org).boardsRepo { await store.loadRepoBoards(org: org, repo: repo) }
            working = false
        }
    }
}

private extension ProjectsLandingView.BoardChange {
    var isDestructive: Bool {
        switch self {
        case .unlink, .close: true
        case .link, .reopen: false
        }
    }
}
