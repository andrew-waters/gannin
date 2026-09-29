import SwiftUI

/// The Projects page before a board is picked: the org's open boards.
struct ProjectsLandingView: View {
    @Environment(ProjectStore.self) private var store
    let org: String
    let onOpen: (Int) -> Void

    var body: some View {
        let boards = store.boardLists[org] ?? []
        List {
            Section {
                if boards.isEmpty {
                    Text("No open project boards, or Gannin can't see them yet. Reading boards needs project access.")
                        .foregroundStyle(.secondary)
                }
                ForEach(boards) { board in
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
                }
            } header: {
                Text("Project boards")
            }
        }
        .task(id: org) { await store.loadBoards(org: org) }
    }
}
