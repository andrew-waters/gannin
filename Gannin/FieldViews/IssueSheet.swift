import SwiftUI

extension IssueReference: Identifiable {}

/// An issue opened from a view, in the drawer over it: what it is and
/// where it sits across the top, then the description, plans and linked PRs
/// beside its board fields (edited and written from here, as in the issue
/// window) and investment category; one column when the drawer is narrow.
struct IssueSheet: View {
    @Environment(IssueStore.self) private var issueStore
    @Environment(DetailStore.self) private var details
    @Environment(OrgStore.self) private var orgs
    @Environment(OrgConfigStore.self) private var configs
    @Environment(\.navigate) private var navigate
    @Environment(\.openAsPage) private var openAsPage
    @Environment(\.openWindow) private var openWindow

    let reference: IssueReference
    let signals: IssueSignals?
    /// Room for the fields beside the description rather than under it.
    var isWide = true
    /// Where it is among the view's issues, as (number, total).
    var position: (Int, Int)?
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    let onClose: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        let record = issueStore.history(for: reference.org)?.issues[reference.id]
        VStack(spacing: 0) {
            header(record)
            Divider()
            if isWide {
                HStack(spacing: 0) {
                    Form { mainSections(record) }
                        .formStyle(.grouped)
                        .frame(minWidth: 480, maxWidth: .infinity)
                    Divider()
                    Form { fieldSections }
                        .formStyle(.grouped)
                        .frame(width: 360)
                }
            } else {
                Form {
                    fieldSections
                    mainSections(record)
                }
                .formStyle(.grouped)
            }
        }
        .task(id: reference.id) { await details.load(reference.id) }
        .loadsHarness(org: reference.org)
        // Arrows and Esc when nothing inside wants them (a field being
        // typed in keeps its arrows).
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onChange(of: reference.id) { isFocused = true }
        .onKeyPress(.leftArrow) {
            guard let onPrevious else { return .ignored }
            onPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard let onNext else { return .ignored }
            onNext()
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    @ViewBuilder
    private func mainSections(_ record: IssueRecord?) -> some View {
        HarnessIssueSection(reference: reference)
        IssueTimelineSection(reference: reference)
        if let record, !record.linkedPullRequests.isEmpty {
            Section(header: SectionHeader(title: "Linked pull requests", count: record.linkedPullRequests.count)) {
                ForEach(record.linkedPullRequests, id: \.url) { pr in
                    HStack(spacing: 8) {
                        Link("#\(String(pr.number))", destination: pr.url)
                        Text(pr.mergedAt == nil ? pr.state.lowercased() : "merged").foregroundStyle(.secondary)
                        Spacer()
                        if let last = pr.activityAt.max() {
                            Text("active").font(.caption).foregroundStyle(.secondary)
                            RelativeDate(date: last).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        DescriptionSections(id: reference.id, url: reference.url)
    }

    @ViewBuilder
    private var fieldSections: some View {
        if !configs.config(for: reference.org).investmentConfig.trackedBy.isBoardField {
            Section("Investment") {
                CategoriseMenu(issueID: reference.id, org: reference.org)
            }
        }
        ProjectFieldsSections(org: reference.org, issueID: reference.id)
    }

    private func header(_ record: IssueRecord?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(reference.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if let position {
                    HStack(spacing: 6) {
                        Button { onPrevious?() } label: { Image(systemName: "chevron.left") }
                            .disabled(onPrevious == nil)
                            .help("Previous issue (Left Arrow)")
                        Text(verbatim: "\(position.0) of \(position.1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button { onNext?() } label: { Image(systemName: "chevron.right") }
                            .disabled(onNext == nil)
                            .help("Next issue (Right Arrow)")
                    }
                    .buttonStyle(.borderless)
                }
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
            }
            HStack(spacing: 10) {
                if let record { Pill(text: state(record), color: stateColor(record)) }
                Link(destination: reference.url) {
                    Text(verbatim: "\(reference.repo)#\(reference.number)")
                }
                Spacer()
                // A real page: navigate would open the drawer again.
                if let open = openAsPage ?? navigate {
                    Button("Open as Page") {
                        onClose()
                        open(.issueReference(reference))
                    }
                }
                Button("Open in Window") {
                    onClose()
                    openWindow(value: reference)
                }
                #if os(macOS)
                StartSessionButton(reference: reference)
                #endif
            }
            if let record {
                facts(record)
            }
        }
        .padding(20)
    }

    private func facts(_ record: IssueRecord) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 10) {
            if let status = signals?.status {
                fact("Status", signals?.timeInStatus.map { "\(status), \($0.compactDuration)" } ?? status)
            }
            if let inProgress = signals?.inProgress { fact("In progress", inProgress.compactDuration) }
            if !record.assignees.isEmpty { people("Assignees", record.assignees) }
            if let type = record.issueType { fact("Type", type) }
            fact("Created", record.createdAt.formatted(date: .abbreviated, time: .omitted))
            if let author = record.author { people("Opened by", [author]) }
            if let flags = signals?.flags, !flags.isEmpty {
                fact("Attention", flags.map(\.rawValue).joined(separator: ", "))
            }
        }
    }

    /// Avatars with names, from the org's members where Gannin has them.
    private func people(_ label: String, _ logins: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            ForEach(logins, id: \.self) { login in
                let person = person(login)
                HStack(spacing: 6) {
                    Avatar(url: person.avatarUrl, size: 20)
                    Text(person.displayName).lineLimit(1)
                }
                .help(login)
            }
        }
    }

    private func person(_ login: String) -> Person {
        orgs.snapshot(for: reference.org)?.members.first { $0.login == login }
            ?? Person(login: login, name: nil, avatarUrl: URL(string: "https://github.com/\(login).png?size=64"))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).lineLimit(2)
        }
    }

    private func state(_ record: IssueRecord) -> String {
        record.isOpen ? "Open" : record.isNotPlanned ? "Not planned" : "Completed"
    }

    private func stateColor(_ record: IssueRecord) -> Color {
        record.isOpen ? .green : record.isNotPlanned ? .secondary : .purple
    }
}
