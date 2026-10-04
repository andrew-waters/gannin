import SwiftUI

/// A project board, GitHub style: its saved views as tabs, each opening with
/// its own filter, layout, grouping, sort and fields. Changes here are local.
struct ProjectBoardView: View {
    enum Mode: Hashable {
        case layout(BoardView.Layout)
        case insights
    }

    @Environment(ProjectStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.navigate) private var navigate
    @Environment(\.openURL) private var openURL
    @Environment(\.newIssue) private var newIssue
    let org: String
    let number: Int

    @State private var viewID: String?
    @State private var filter = ""
    @State private var appliedFilter = ""
    @State private var mode: Mode = .layout(.table)
    @State private var groupBy: String?
    @State private var columnBy: String?
    @State private var sortBy: [BoardView.Sort] = []

    var body: some View {
        VStack(spacing: 0) {
            if let cache = store.cache(org: org, number: number) {
                let board = cache.board
                header(board)
                Divider()
                content(board)
            } else if let error = store.errors[ProjectStore.key(org, number)] {
                ContentUnavailableView {
                    Label("Couldn't load the project", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        Task {
                            if viewID == nil {
                                await loadBoard(force: true)
                            } else {
                                await store.sync(org: org, number: number, filter: appliedFilter, force: true)
                            }
                        }
                    }
                }
            } else {
                ProgressView("Loading project").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem { NewIssueButton(context: NewIssueContext(org: org, board: number, boardFilter: appliedFilter)) }
        }
        .task(id: "\(org)#\(number)") { await loadBoard() }
        .task(id: "\(org)#\(number) \(viewID ?? "") \(appliedFilter)") {
            guard viewID != nil else { return }
            await store.sync(org: org, number: number, filter: appliedFilter)
        }
    }

    /// The board's fields and views, then its first view, so the first items
    /// synced are that view's rather than everything on the board.
    private func loadBoard(force: Bool = false) async {
        await store.loadDefinition(org: org, number: number, force: force)
        guard viewID == nil, let cache = store.cache(org: org, number: number) else { return }
        if let first = cache.board.views.first {
            select(first)
        } else {
            // A board with no saved views at all: fall back to everything.
            viewID = ""
        }
    }

    private func currentView(_ board: Board) -> BoardView? {
        board.views.first { $0.id == viewID }
    }

    /// Opens a saved view with its own settings.
    private func select(_ view: BoardView) {
        viewID = view.id
        filter = view.filter
        appliedFilter = view.filter
        mode = .layout(view.layout == .roadmap ? .table : view.layout)
        groupBy = view.groupBy.first
        columnBy = view.columnBy.first ?? (view.layout == .board ? "Status" : nil)
        sortBy = view.sortBy
    }

    // MARK: Header

    private func header(_ board: Board) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(board.title).font(.title3.weight(.semibold))
                if store.isLoading(org: org, number: number) {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let items = store.items(org: org, number: number, filter: appliedFilter) {
                    Text("\(items.count) items").foregroundStyle(.secondary).monospacedDigit()
                }
                Link(destination: currentView(board).flatMap { URL(string: "\(board.url.absoluteString)/views/\($0.number)") } ?? board.url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(board.views) { view in
                        Button { select(view) } label: {
                            Label(view.name, systemImage: view.layout.systemImage)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(viewID == view.id ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(viewID == view.id ? .primary : .secondary)
                    }
                }
            }
            .scrollIndicators(.never)
            controls(board)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func controls(_ board: Board) -> some View {
        let groupable = board.fields.filter(\.isGroupable).map(\.name)
        let columnable = board.fields.filter { $0.dataType == "SINGLE_SELECT" || $0.dataType == "ITERATION" }.map(\.name)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Filter, as on GitHub: -status:Done label:bug", text: $filter)
                .textFieldStyle(.roundedBorder)
                .onSubmit { appliedFilter = filter.trimmingCharacters(in: .whitespaces) }
            if let view = currentView(board), appliedFilter != view.filter {
                Button("Reset") { filter = view.filter; appliedFilter = view.filter }
            }
            Picker("Layout", selection: $mode) {
                Label("Table", systemImage: "tablecells").tag(Mode.layout(.table))
                Label("Board", systemImage: "rectangle.split.3x1").tag(Mode.layout(.board))
                Label("Insights", systemImage: "chart.bar.xaxis").tag(Mode.insights)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if mode == .layout(.board) {
                fieldMenu("Columns", selection: $columnBy, fields: columnable, allowsNone: false)
            }
            if mode != .insights {
                fieldMenu(mode == .layout(.board) ? "Swimlanes" : "Group", selection: $groupBy, fields: groupable, allowsNone: true)
                sortMenu(groupable)
            }
        }
        .controlSize(.small)
    }

    private func fieldMenu(_ title: String, selection: Binding<String?>, fields: [String], allowsNone: Bool) -> some View {
        Menu {
            if allowsNone {
                Button { selection.wrappedValue = nil } label: { check("None", selection.wrappedValue == nil) }
                Divider()
            }
            ForEach(fields, id: \.self) { field in
                Button { selection.wrappedValue = field } label: { check(field, selection.wrappedValue == field) }
            }
        } label: {
            Text(selection.wrappedValue.map { "\(title): \($0)" } ?? "\(title): None")
        }
        .fixedSize()
    }

    private func sortMenu(_ fields: [String]) -> some View {
        Menu {
            Button { sortBy = [] } label: { check("Board order", sortBy.isEmpty) }
            Divider()
            ForEach(fields, id: \.self) { field in
                Button {
                    let current = sortBy.first
                    sortBy = [BoardView.Sort(field: field, descending: current?.field == field ? !(current?.descending ?? false) : false)]
                } label: {
                    check(field + (sortBy.first?.field == field ? (sortBy.first?.descending == true ? " ↓" : " ↑") : ""), sortBy.first?.field == field)
                }
            }
        } label: {
            Text(sortBy.first.map { "Sort: \($0.field) \($0.descending ? "↓" : "↑")" } ?? "Sort: Board order")
        }
        .fixedSize()
    }

    @ViewBuilder
    private func check(_ title: String, _ isOn: Bool) -> some View {
        if isOn { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ board: Board) -> some View {
        if let items = store.items(org: org, number: number, filter: appliedFilter) {
            let visible = currentView(board)?.visibleFields ?? ["Title", "Assignees", "Status"]
            let sorted = BoardLayout.sorted(items, by: sortBy)
            switch mode {
            case .layout(.board):
                BoardColumnsView(board: board, items: sorted, columnBy: columnBy ?? "Status", swimlaneBy: groupBy, visibleFields: visible, open: open) { value in
                    // A column's +: New Issue in that column.
                    var context = NewIssueContext(org: org, board: number, boardFilter: appliedFilter)
                    if let value { context.fields[columnBy ?? "Status"] = value.display }
                    newIssue?(context)
                }
            case .insights:
                BoardInsightsView(org: org, board: board, items: items)
            default:
                BoardTableView(board: board, items: sorted, groupBy: groupBy, visibleFields: visible, open: open)
            }
        } else {
            ProgressView("Loading items").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Issues and PRs over the board, or in windows of their own outside a
    /// main window; drafts on GitHub.
    private func open(_ item: BoardItem) {
        guard let id = item.contentID, let number = item.number, let repo = item.repo, let url = item.url else {
            return
        }
        switch item.kind {
        case .issue:
            let reference = IssueReference(org: org, id: id, number: number, title: item.title, repo: repo, url: url)
            if let navigate { navigate(.issueReference(reference)) } else { openWindow(value: reference) }
        case .pullRequest:
            let reference = PullRequestReference(org: org, id: id, number: number, title: item.title, repo: repo, url: url)
            if let navigate { navigate(.pullRequestReference(reference)) } else { openWindow(value: reference) }
        default:
            openURL(url)
        }
    }
}

// MARK: - Sorting and grouping

enum BoardLayout {
    /// Items sorted by each field in turn; empty values go last either way.
    static func sorted(_ items: [BoardItem], by sorts: [BoardView.Sort]) -> [BoardItem] {
        guard !sorts.isEmpty else { return items }
        return items.sorted { a, b in
            for sort in sorts {
                let x = a.value(sort.field), y = b.value(sort.field)
                if x == y { continue }
                guard let x else { return false }
                guard let y else { return true }
                if IssueFieldValue.ascending(x, y) { return !sort.descending }
                if IssueFieldValue.ascending(y, x) { return sort.descending }
            }
            return false
        }
    }

    struct Group: Identifiable {
        let name: String
        let value: IssueFieldValue?
        let items: [BoardItem]

        var id: String { name }
    }

    /// Items grouped by a field: board order for options and iterations,
    /// empty values last.
    static func groups(_ items: [BoardItem], by field: String?, board: Board, includeEmptyOptions: Bool = false) -> [Group] {
        guard let field else { return [Group(name: "", value: nil, items: items)] }
        var byName: [String: (IssueFieldValue?, [BoardItem])] = [:]
        for item in items {
            let value = item.value(field)
            let name = value?.display ?? "No \(field)"
            byName[name, default: (value, [])].1.append(item)
        }
        if includeEmptyOptions, let options = board.field(named: field)?.options {
            for (index, option) in options.enumerated() where byName[option.name] == nil {
                let value: IssueFieldValue = option.start.map { .iteration(title: option.name, start: $0) } ?? .option(name: option.name, position: index)
                byName[option.name] = (value, [])
            }
        }
        return byName
            .map { Group(name: $0.key, value: $0.value.0, items: $0.value.1) }
            .sorted { a, b in
                switch (a.value, b.value) {
                case (nil, nil): a.name < b.name
                case (nil, _): false
                case (_, nil): true
                case (let x?, let y?): IssueFieldValue.ascending(x, y)
                }
            }
    }

    /// GitHub's single-select colour names as system colours.
    static func color(_ name: String?) -> Color {
        switch name {
        case "BLUE": .blue
        case "GREEN": .green
        case "YELLOW": .yellow
        case "ORANGE": .orange
        case "RED": .red
        case "PINK": .pink
        case "PURPLE": .purple
        default: .gray
        }
    }
}

extension BoardItem {
    /// The page an issue or PR on a board opens; drafts have none.
    func page(org: String) -> DetailSelection? {
        guard let id = contentID, let number, let repo, let url else { return nil }
        switch kind {
        case .issue: return .issueReference(IssueReference(org: org, id: id, number: number, title: title, repo: repo, url: url))
        case .pullRequest: return .pullRequestReference(PullRequestReference(org: org, id: id, number: number, title: title, repo: repo, url: url))
        default: return nil
        }
    }
}
