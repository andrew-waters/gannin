import SwiftUI

/// A review workflow run on the review's Overview: each stage's steps, how
/// far each got, what every round found, and which didn't run and why.
struct ReviewRunSection: View {
    let run: ReviewRun

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.workflowName).font(.title3.weight(.semibold))
                Text(progress).foregroundStyle(.secondary)
            }
            ForEach(0..<run.stageCount, id: \.self) { stage in
                VStack(alignment: .leading, spacing: 0) {
                    Text("Stage \(stage + 1)\(run.steps(inStage: stage).count > 1 ? ", side by side" : "")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                    ForEach(run.steps(inStage: stage), id: \.self) { index in
                        ReviewStepRow(step: run.steps[index])
                        if index != run.steps(inStage: stage).last { Divider().padding(.leading, 10) }
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var progress: String {
        if run.finishedAt != nil {
            let skipped = run.steps.filter { $0.state == .skipped }.count
            return skipped == 0 ? "Finished" : "Finished, \(skipped) not run"
        }
        return "Stage \(run.stage + 1) of \(run.stageCount)"
    }
}

/// One step: its specialist, provider and model, its state, and each
/// round's findings.
private struct ReviewStepRow: View {
    let step: ReviewStepRun
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let focus = step.focus {
                    Text("Focus: \(focus)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(step.results.enumerated()), id: \.offset) { round, result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Round \(round + 1): \(result.findings.count) finding\(result.findings.count == 1 ? "" : "s")")
                            .font(.callout.weight(.medium))
                        ForEach(Array(result.findings.enumerated()), id: \.offset) { _, finding in
                            Text("`\(finding.path)\(finding.line.map { ":\($0)" } ?? "")` \(finding.comment)")
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if step.results.isEmpty, step.state != .skipped {
                    Text(step.state == .waiting ? "Waits for the stage before, or for room to start." : "Reviewing.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if step.rounds > 1 {
                    Text("\(step.results.count) of \(step.rounds) rounds").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var symbol: String {
        switch step.state {
        case .waiting: "clock"
        case .running: "ellipsis.circle"
        case .done: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private var color: Color {
        switch step.state {
        case .waiting: .secondary
        case .running: .accentColor
        case .done: .green
        case .skipped: .orange
        }
    }

    /// Where it ran, and why it didn't when it was skipped.
    private var detail: String {
        let provider = ProviderID(name: step.provider)?.title ?? step.provider
        let runsOn = step.model.map { "\(provider), \($0)" } ?? provider
        guard let note = step.note else { return runsOn }
        return step.state == .skipped ? "Not run: \(note)" : "\(runsOn). \(note)"
    }
}

/// What an interactive session's workflow did: its name, the steps that
/// prepared it, and notes from steps after it (the reviews they started).
struct SessionWorkflowSection: View {
    let workflow: SessionWorkflow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(workflow.name, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout.weight(.semibold))
            if let before = workflow.before, !before.isEmpty {
                Text("Prepared by \(before.map(\.title).joined(separator: ", ")) before it started, in its brief.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let after = workflow.after {
                Text("Reviews each pull request it opens with \(after.steps.count) step\(after.steps.count == 1 ? "" : "s") after it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(workflow.notes ?? [], id: \.self) { note in
                Text(note).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
