import SwiftUI

/// Settings › R&D: what the work is called, which issues count and how time
/// is found. Kept in the project's harness; the accounting year is the
/// org's, in Working Time.
struct RDSettingsSection: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(ProjectStore.self) private var projects

    let org: String

    @State private var name = ""
    @State private var labels = ""
    @FocusState private var focused: Field?

    private enum Field {
        case name, labels
    }

    private enum Kind: String, CaseIterable {
        case byHand = "Marked by hand"
        case categories = "Investment categories"
        case labels = "GitHub labels"
        case projectField = "A board field"
    }

    private var rnd: RDConfig { configs.config(for: org).rndConfig }
    private var boards: [OrgProject] { projects.boardLists[org] ?? [] }

    var body: some View {
        let rnd = rnd
        Section {
            TextField("Name", text: $name, prompt: Text(RDConfig.defaultName))
                .leadingTextBox("Name")
                .focused($focused, equals: .name)
                .onSubmit(commitName)
            Picker("What counts", selection: kindBinding(rnd.qualifiedBy)) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            qualificationDetail(rnd.qualifiedBy)
        } header: {
            Text("What counts")
        } footer: {
            Text("Issues can also be marked by hand on the R&D Time page, with a share and a rationale; a mark wins over this. Sub-issues count when their parent does. The page's ranges follow the accounting year and periods in Working Time.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            name = rnd.name ?? ""
            if case .labels(let list) = rnd.qualifiedBy { labels = list.joined(separator: ", ") }
        }
        .onChange(of: focused) { old, _ in
            if old == .name { commitName() }
            if old == .labels { commitLabels() }
        }

        let options = rnd.activityOptions
        Section {
            LabeledContent("Source", value: rnd.timeSources.map(\.name).joined(separator: ", "))
            Picker("Split each day", selection: Binding { options.splitBy } set: { value in updateActivity { $0.weighting = value } }) {
                ForEach(RDActivityOptions.Weighting.allCases) { Text($0.name).tag($0) }
            }
            Picker("Days with no activity", selection: Binding { options.quiet } set: { value in updateActivity { $0.quietDays = value } }) {
                ForEach(RDActivityOptions.QuietDays.allCases) { Text($0.name).tag($0) }
            }
            Toggle("Count reviews", isOn: Binding { options.reviews } set: { value in updateActivity { $0.countsReviews = value } })
            Toggle("Count issue comments", isOn: Binding { options.comments } set: { value in updateActivity { $0.countsComments = value } })
        } header: {
            Text("How time is found")
        } footer: {
            Text("Each working day's hours, from the working week and each person's own pattern, less bank holidays and time off, are split across the issues they committed to, reviewed or commented on that day. A pull request's activity goes to the issues it closes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        let marks = (rnd.marks ?? [:]).sorted { ($0.value.issue ?? $0.key) < ($1.value.issue ?? $1.key) }
        Section {
            if marks.isEmpty {
                Text("No issues marked by hand.").foregroundStyle(.secondary)
            }
            ForEach(marks, id: \.key) { id, mark in
                LabeledContent {
                    Button("Clear") {
                        configs.updateRD(org) { rnd in
                            rnd.marks?[id] = nil
                            if rnd.marks?.isEmpty == true { rnd.marks = nil }
                        }
                    }
                } label: {
                    Text(mark.issue ?? id)
                    Text(markSummary(mark))
                }
            }
        } header: {
            Text("Marked issues")
        }
    }

    private func markSummary(_ mark: RDMark) -> String {
        let counts = mark.counts ? (mark.clampedShare < 1 ? "Counts, \(RDExport.percent(mark.clampedShare))" : "Counts") : "Doesn't count"
        return [counts, mark.note].compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder
    private func qualificationDetail(_ qualification: RDQualification) -> some View {
        switch qualification {
        case .byHand:
            EmptyView()
        case .categories(let ids):
            ForEach(configs.config(for: org).investmentConfig.categories) { category in
                Toggle(category.name, isOn: Binding {
                    ids.contains(category.id)
                } set: { on in
                    let chosen = on ? ids + [category.id] : ids.filter { $0 != category.id }
                    setQualification(.categories(chosen))
                })
                .checkboxToggle()
            }
        case .labels:
            TextField("Labels", text: $labels, prompt: Text("r&d, research"))
                .leadingTextBox("Labels")
                .focused($focused, equals: .labels)
                .onSubmit(commitLabels)
        case .projectField(let number, let title, let field, let options):
            Picker("Board", selection: Binding {
                number
            } set: { newNumber in
                setQualification(.projectField(projectNumber: newNumber, projectTitle: boards.first { $0.number == newNumber }?.title ?? "", field: "", options: []))
            }) {
                if number == 0 || !boards.contains(where: { $0.number == number }) {
                    Text(number == 0 ? (boards.isEmpty ? "Loading boards" : "Choose a board") : "Project \(number)").tag(number)
                }
                ForEach(boards) { Text($0.title).tag($0.number) }
            }
            .task { await projects.loadBoards(org: org) }
            if number != 0 {
                let fields = projects.cache(org: org, number: number)?.board.fields.filter { $0.dataType == "SINGLE_SELECT" }
                Picker("Field", selection: Binding {
                    field
                } set: { newField in
                    setQualification(.projectField(projectNumber: number, projectTitle: title, field: newField, options: []))
                }) {
                    if field.isEmpty || !(fields ?? []).contains(where: { $0.name == field }) {
                        Text(field.isEmpty ? (fields == nil ? "Loading fields" : "Choose a field") : field).tag(field)
                    }
                    ForEach(fields ?? []) { Text($0.name).tag($0.name) }
                }
                .task(id: number) { await projects.loadDefinition(org: org, number: number) }
                if let choices = fields?.first(where: { $0.name == field })?.options {
                    ForEach(choices) { option in
                        Toggle(option.name, isOn: Binding {
                            options.contains(option.name)
                        } set: { on in
                            let chosen = on ? options + [option.name] : options.filter { $0 != option.name }
                            setQualification(.projectField(projectNumber: number, projectTitle: title, field: field, options: chosen))
                        })
                        .checkboxToggle()
                    }
                }
            }
        }
    }

    private func kindBinding(_ qualification: RDQualification) -> Binding<Kind> {
        Binding {
            switch qualification {
            case .byHand: .byHand
            case .categories: .categories
            case .labels: .labels
            case .projectField: .projectField
            }
        } set: { kind in
            switch kind {
            case .byHand: setQualification(.byHand)
            case .categories: setQualification(.categories([]))
            case .labels:
                labels = ""
                setQualification(.labels([]))
            case .projectField: setQualification(.projectField(projectNumber: 0, projectTitle: "", field: "", options: []))
            }
        }
    }

    private func setQualification(_ qualification: RDQualification) {
        configs.updateRD(org) { $0.qualification = qualification }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        configs.updateRD(org) { $0.name = trimmed.isEmpty ? nil : trimmed }
    }

    private func commitLabels() {
        guard case .labels = rnd.qualifiedBy else { return }
        let list = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        setQualification(.labels(list))
    }

    private func updateActivity(_ change: (inout RDActivityOptions) -> Void) {
        configs.updateRD(org) { rnd in
            var options = rnd.activityOptions
            change(&options)
            rnd.activity = options
        }
    }
}
