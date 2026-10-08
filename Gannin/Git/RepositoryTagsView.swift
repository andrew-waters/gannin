import SwiftUI

/// The clone's tags, newest first, with which are on origin: create,
/// push and delete them, here and there.
struct RepositoryTagsView: View {
    let repository: LocalRepository
    @State private var search = ""
    @State private var deleting: GitTag?

    var body: some View {
        let words = search.lowercased().split(separator: " ")
        let tags = repository.tags.filter { tag in words.allSatisfy { tag.name.lowercased().contains($0) || tag.subject.lowercased().contains($0) } }
        let onlyHere = repository.remoteTags.map { remote in repository.tags.filter { !remote.contains($0.name) }.count } ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FilterSearchField(text: $search, prompt: "Tags")
                Spacer()
                if onlyHere > 0 {
                    Button("Push \(onlyHere == 1 ? "1 Tag" : "\(onlyHere) Tags")") { Task { await repository.pushAllTags() } }
                        .help("Push every tag that's only here to origin")
                }
                Button("New Tag") { repository.creatingTag = CreateTagRequest() }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if repository.tags.isEmpty {
                ContentUnavailableView("No tags yet", systemImage: "tag", description: Text("Tag a commit to mark a release."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(tags) { row($0) }
            }
        }
        .task(id: repository.root) { await repository.loadRemoteTags() }
        .confirmationDialog("Delete the tag \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { tag in
            Button("Delete Here", role: .destructive) { Task { await repository.deleteTag(tag.name, here: true, onOrigin: false) } }
            if repository.remoteTags?.contains(tag.name) == true {
                Button("Delete Here and on origin", role: .destructive) { Task { await repository.deleteTag(tag.name, here: true, onOrigin: true) } }
            }
        } message: { _ in
            Text("Deleting it on origin takes it away for everyone. A GitHub release on it becomes a draft.")
        }
    }

    private func row(_ tag: GitTag) -> some View {
        let onOrigin = repository.remoteTags.map { $0.contains(tag.name) }
        return HStack(spacing: 8) {
            Image(systemName: tag.isAnnotated ? "tag.fill" : "tag")
                .foregroundStyle(.secondary)
                .help(tag.isAnnotated ? "Annotated: it has a message, author and date of its own" : "Lightweight: a name for the commit")
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tag.name).fontWeight(.medium)
                    Text(tag.sha).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if !tag.subject.isEmpty {
                    Text(tag.subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let date = tag.date {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch onOrigin {
            case true?:
                Text("On origin").font(.caption).foregroundStyle(.secondary)
            case false?:
                Button("Push") { Task { await repository.pushTag(tag) } }
                    .controlSize(.small)
                    .help("Only here: push it to origin")
            case nil:
                EmptyView()
            }
        }
        .contextMenu {
            if onOrigin == false {
                Button("Push to origin") { Task { await repository.pushTag(tag) } }
            }
            Button("New Branch from \(tag.name)") { repository.creatingBranch = CreateBranchRequest(base: tag.name) }
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tag.name, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { deleting = tag }
        }
    }
}

/// A tag on a commit: lightweight, or annotated when it has a message, and
/// pushed straight away if wanted.
struct NewTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    let repository: LocalRepository
    @State var target: String
    @State private var name = ""
    @State private var message = ""
    @State private var push = true
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let exists = repository.tags.contains { $0.name == trimmedName }
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text(suggestion ?? "v1.0.0"))
                TextField("On", text: $target, prompt: Text("HEAD"))
                    .help("A branch, tag or commit; HEAD is the commit checked out")
                TextField("Message", text: $message, prompt: Text("Optional: makes it an annotated tag"), axis: .vertical)
                    .lineLimit(2...8)
                Toggle("Push to origin", isOn: $push)
            } header: {
                Text("New tag in \(repository.repo)")
            } footer: {
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                } else if exists {
                    Text("There's a tag called \(trimmedName) already.").foregroundStyle(.red)
                } else {
                    Text("With a message it's annotated, as releases usually are: the first line is the title, the rest the notes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(push ? "Create and Push" : "Create Tag") {
                    Task {
                        working = true
                        error = await repository.createTag(trimmedName, target: target, message: message, push: push)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .disabled(trimmedName.isEmpty || exists || working)
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// The next patch version after the newest `v1.2.3` tag.
    private var suggestion: String? {
        guard let latest = repository.tags.first(where: { $0.name.hasPrefix("v") && $0.name.dropFirst().split(separator: ".").count == 3 }) else { return nil }
        let parts = latest.name.dropFirst().split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return "v\(parts[0]).\(parts[1]).\(parts[2] + 1)"
    }
}
