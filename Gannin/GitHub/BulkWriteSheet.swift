import SwiftUI

/// Confirms a batch of GitHub writes, then makes them one at a time, ticking
/// each off (or marking it failed with why) as it goes, and stays open until
/// Done so the result can be read.
struct BulkWriteSheet: View {
    struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    let title: String
    let explanation: String
    let action: String
    let rows: [Row]
    /// Does the write for one row.
    let perform: (Row) async throws -> Void
    let onClose: () -> Void

    @State private var states: [String: RowState] = [:]
    @State private var done = 0
    @State private var isWriting = false
    @State private var finished = false

    private enum RowState: Equatable {
        case writing
        case done
        case failed(String)
    }

    var body: some View {
        let failed = states.values.filter { if case .failed = $0 { true } else { false } }.count
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            Text(explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollViewReader { proxy in
                List(rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        icon(states[row.id])
                            .frame(width: 16, height: 16)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).lineLimit(1)
                            Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if case .failed(let message) = states[row.id] {
                                Text(message).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .id(row.id)
                }
                .onChange(of: done) {
                    if rows.indices.contains(done) {
                        withAnimation { proxy.scrollTo(rows[done].id, anchor: .center) }
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 360)
            HStack {
                if isWriting {
                    ProgressView(value: Double(done), total: Double(rows.count)).frame(width: 160)
                    Text("\(done) of \(rows.count)").monospacedDigit().foregroundStyle(.secondary)
                } else if finished {
                    Text(failed == 0 ? (rows.count == 1 ? "Done on GitHub." : "All \(rows.count) done on GitHub.") : "\(rows.count - failed) done, \(failed) failed.")
                        .foregroundStyle(failed == 0 ? Color.secondary : .red)
                }
                Spacer()
                if finished {
                    Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel, action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isWriting)
                    Button(action) { Task { await write() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isWriting || rows.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(isWriting)
    }

    @ViewBuilder
    private func icon(_ state: RowState?) -> some View {
        switch state {
        case nil: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .writing: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func write() async {
        isWriting = true
        for (index, row) in rows.enumerated() {
            states[row.id] = .writing
            do {
                try await perform(row)
                states[row.id] = .done
            } catch {
                states[row.id] = .failed(error.localizedDescription)
            }
            done = index + 1
        }
        isWriting = false
        finished = true
    }
}
