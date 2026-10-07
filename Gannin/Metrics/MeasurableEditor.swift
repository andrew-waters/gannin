import SwiftUI

/// A measurable's name, cadence, source (one of Gannin's numbers or
/// entered by hand, in a unit), team, owner and target. Kept with the
/// team's settings, so in the harness once the org keeps them there.
struct MeasurableEditor: View {
    @Environment(OrgConfigStore.self) private var configs
    @Environment(OrgStore.self) private var orgs
    @Environment(\.dismiss) private var dismiss
    let org: String
    /// Nil for a new one.
    let measurable: Measurable?
    let cadence: ScorecardCadence

    @State private var draft = Measurable(name: "", cadence: .weekly)
    @State private var confirmingDelete = false

    var body: some View {
        let snapshot = orgs.snapshot(for: org)
        let teams = (snapshot?.teams ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let members = (snapshot?.members ?? []).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        Form {
            Section {
                Picker("Measures", selection: Binding(get: { draft.metric }, set: { pick($0) })) {
                    Text("A number entered by hand").tag(ScorecardMetric?.none)
                    Divider()
                    ForEach(ScorecardMetric.allCases) { Text($0.title).tag(Optional($0)) }
                }
                TextField("Name", text: $draft.name, prompt: Text(draft.metric?.title ?? "AWS costs"))
                Picker("Every", selection: $draft.cadence) {
                    ForEach(ScorecardCadence.allCases) { Text($0.noun.capitalized).tag($0) }
                }
                if draft.isManual {
                    Picker("Unit", selection: $draft.unit) {
                        ForEach(Measurable.Unit.allCases) { Text($0.title).tag($0) }
                    }
                    if draft.unit == .currency {
                        TextField("Currency", text: Binding(get: { draft.currency ?? "" }, set: { draft.currency = $0.isEmpty ? nil : $0.uppercased() }),
                                  prompt: Text(Locale.current.currency?.identifier ?? "GBP"))
                    }
                }
            } footer: {
                Text(draft.metric.map { "\($0.detail), worked out from merged PRs each \(draft.cadence.noun)\(draft.team == nil ? "" : " for the team's people")." }
                     ?? "You enter it each \(draft.cadence.noun) in its cell on the scorecard: costs, incidents, NPS, anything Gannin can't see.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Target") {
                Picker("Target", selection: $draft.comparison) {
                    ForEach(Measurable.Comparison.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField("Value", value: $draft.target, format: .number, prompt: Text("None"))
                        .textFieldStyle(.roundedBorder)
                    Text(unitLabel).foregroundStyle(.secondary)
                }
                if draft.metric?.accumulates == true {
                    Text("A \(draft.cadence.noun) under way is held to its share of the target so far.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Who") {
                Picker("Team", selection: $draft.team) {
                    Text("The whole org").tag(String?.none)
                    if !teams.isEmpty { Divider() }
                    ForEach(teams) { Text($0.name).tag(Optional($0.slug)) }
                }
                Picker("Owner", selection: $draft.owner) {
                    Text("No one").tag(String?.none)
                    if !members.isEmpty { Divider() }
                    ForEach(members, id: \.login) { Text($0.displayName).tag(Optional($0.login)) }
                }
            }
            Section("Notes") {
                TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.isEmpty ? nil : $0 }), prompt: Text("Where the number comes from, what good looks like"), axis: .vertical)
                    .lineLimit(1...4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if measurable != nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(measurable == nil ? "Add" : "Save", action: save)
                    .disabled(name.isEmpty)
            }
        }
        .confirmationDialog("Delete \(draft.name)?", isPresented: $confirmingDelete) {
            Button("Delete Measurable", role: .destructive) {
                configs.updateMeasurables(org) { $0.removeAll { $0.id == draft.id } }
                dismiss()
            }
        } message: {
            Text(draft.values.isEmpty ? "It comes off the scorecard for everyone in \(org)." : "It comes off the scorecard for everyone in \(org), with the \(draft.values.count) values entered for it.")
        }
        .onAppear {
            draft = measurable ?? Measurable(name: "", cadence: cadence)
        }
    }

    private var name: String {
        let typed = draft.name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? (draft.metric?.title ?? "") : typed
    }

    private var unitLabel: String {
        switch draft.effectiveUnit {
        case .number: draft.metric?.countUnit(per: draft.cadence) ?? ""
        case .currency: draft.currency ?? Locale.current.currency?.identifier ?? "GBP"
        case .percent: "%"
        case .hours: "hours"
        case .days: "days"
        }
    }

    /// A metric brings its own direction: more PRs is better, a longer
    /// cycle time worse.
    private func pick(_ metric: ScorecardMetric?) {
        if draft.name.isEmpty || draft.name == draft.metric?.title { draft.name = metric?.title ?? "" }
        draft.metric = metric
        if let metric { draft.comparison = metric.higherIsBetter ? .atLeast : .atMost }
    }

    private func save() {
        var saved = draft
        saved.name = name
        configs.updateMeasurables(org) { list in
            if let index = list.firstIndex(where: { $0.id == saved.id }) { list[index] = saved } else { list.append(saved) }
        }
        dismiss()
    }
}
