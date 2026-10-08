import AppKit
import QuickLookUI
import SwiftUI

/// Where an Ask's files go in the harness: `research/<date>-<slug>/`, one
/// folder per conversation, with a README naming it and listing its files.
enum ResearchFolder {
    static func path(for session: CodeSession) -> String {
        let day = session.createdAt.formatted(.iso8601.year().month().day())
        return "research/\(day)-\(session.ask?.slug ?? session.branch)"
    }

    /// The folder's README: the conversation's title and question, and its
    /// files, as a research document the Harness page lists. `existing` is
    /// the README at the head, which only gains the file.
    static func readme(for session: CodeSession, adding name: String, existing: String?) -> String {
        let folder = path(for: session)
        let target = "/\(folder)/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))"
        let link = "- [\(name)](https://github.com/\(session.harnessRepo ?? session.repo)/blob/HEAD\(target)"
        if var existing {
            // Committed again: it's listed already.
            guard !existing.contains(target) else { return existing }
            if !existing.hasSuffix("\n") { existing += "\n" }
            return existing + link + "\n"
        }
        let title = session.title
        let question = (session.ask?.message ?? title).split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
        return """
            ---
            type: research
            status: done
            summary: \(yamlString("Files from an Ask in Gannin: \(title)"))
            created: \(session.createdAt.formatted(.iso8601.year().month().day()))
            ---

            # \(title)

            Files from an Ask conversation in Gannin, each committed by hand.

            ## Question

            \(question)

            ## Files

            \(link)

            """
    }

    /// Quoted for YAML front matter.
    private static func yamlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Commit to Harness, from one file's menu in an Ask's Files: what it is
/// and a preview of it, where it'll go, a warning that it may hold
/// sensitive data, and a box to tick before Commit can be pressed. Return
/// cancels; nothing commits without the click.
struct CommitToHarnessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(OrgConfigStore.self) private var configs
    @Environment(HarnessStore.self) private var harness
    let session: CodeSession
    let file: SessionFile
    @State private var checked = false
    @State private var committing = false
    @State private var committed = false
    @State private var error: String?

    var body: some View {
        let setup = session.harnessRepo.flatMap { configs.config(for: session.org).harness(repo: $0) }
        let destination = "\(ResearchFolder.path(for: session))/\(file.name)"
        let tooLarge = file.size > Int64(HarnessChange.maxDataBytes)
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit to Harness").font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            QuickLookPreview(url: file.url)
                .frame(minHeight: 220, maxHeight: 360)
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.separatorLine) }
            LabeledContent("Goes to") {
                Text("\(destination) in \(session.harnessRepo ?? "the harness")")
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            Text("With a README in its folder naming this conversation and its question, listing the files committed from it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label {
                Text("Exports can hold customer details or other sensitive data. Everyone who can read \(session.harnessRepo ?? "the harness") will see this file, and git keeps it in the history even if it's deleted later. Commit only what belongs there.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            }
            .font(.callout)
            if tooLarge {
                Text("It's over \(ByteCountFormatter.string(fromByteCount: Int64(HarnessChange.maxDataBytes), countStyle: .file)), more than Gannin commits through GitHub's API. Add it to the harness with git instead, if it belongs there.")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if !committed {
                Toggle("I've checked this file and it belongs in the harness", isOn: $checked)
                    .checkboxToggle()
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if committed {
                Label("Committed to \(session.harnessRepo ?? "the harness")", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ChartPalette.good)
            }
            HStack {
                Spacer()
                if committed {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    // The default: Return never commits.
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                    Button(committing ? "Committing" : "Commit \(file.name)") {
                        if let setup { Task { await commit(setup) } }
                    }
                    .disabled(!checked || tooLarge || committing || setup == nil)
                    .help(setup == nil ? "This session's harness isn't one of the org's projects any more." : "Commit this one file to \(setup!.repo)")
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func commit(_ setup: HarnessConfig) async {
        committing = true
        defer { committing = false }
        error = nil
        guard let data = try? Data(contentsOf: file.url) else {
            error = "Couldn't read \(file.name)."
            return
        }
        let folder = ResearchFolder.path(for: session)
        let readmePath = "\(folder)/README.md"
        do {
            try await harness.commit(org: session.org, setup: setup) { head in
                let existing = try await harness.files(setup: setup, at: head, paths: [readmePath])[readmePath] ?? nil
                return HarnessChange(
                    message: "Gannin: \(file.name) from the Ask \"\(session.title)\"",
                    files: [readmePath: ResearchFolder.readme(for: session, adding: file.name, existing: existing)],
                    data: ["\(folder)/\(file.name)": data]
                )
            }
            committed = true
        } catch {
            self.error = "Couldn't commit it: \(error.localizedDescription)"
        }
    }
}

/// Quick Look's own preview of a file: text, CSV, images, PDFs and the rest.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}
