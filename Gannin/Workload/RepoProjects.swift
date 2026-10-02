import SwiftUI

/// A named group of repos: a product, a side project. Focusing on one
/// (the account menu, `OrgConfigStore.setFocus`) leaves every other repo
/// out of the workload, the stats, the scorecard, CI and the issue pages,
/// as excluded repos are. A team setting, so in the harness once the org
/// keeps them there.
struct RepoProject: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    /// `owner/name`.
    var repos: [String]
}

/// Excluded repos, and the focus's: what views check a repo against.
struct RepoExclusion: Hashable {
    let excluded: Set<String>
    /// Nil when nothing's in focus.
    let focus: Set<String>?

    func contains(_ repo: String) -> Bool {
        excluded.contains(repo) || (focus.map { !$0.contains(repo) } ?? false)
    }
}

/// Settings › Repositories: the account's projects, each a name and its
/// repos, picked from those the workload and stats know.
struct RepoProjectsSection: View {
    @Environment(OrgConfigStore.self) private var configs
    let org: String
    /// Every repo there is to pick from.
    let repos: [String]

    var body: some View {
        let projects = configs.baseConfig(for: org).repoProjects
        Section {
            if projects.isEmpty {
                Text("Group repos into projects (a product, a side project) to focus the whole app on one from the account menu.")
                    .foregroundStyle(.secondary)
            }
            ForEach(projects) { project in
                row(project)
            }
            Button("Add Project") {
                configs.update(org) { $0.repoProjects.append(RepoProject(name: "New project", repos: [])) }
            }
        } header: {
            Text("Projects")
        } footer: {
            Text("Focusing on a project leaves every other repo out of the workload, stats, scorecard, CI, Recap and issue pages until you go back to All Repositories. Excluded repos stay out either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ project: RepoProject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: Binding(get: { project.name }, set: { name in update(project.id) { $0.name = name } }))
                    .fontWeight(.medium)
                Button(role: .destructive) {
                    if configs.focus[org] == project.id { configs.setFocus(nil, in: org) }
                    configs.update(org) { $0.repoProjects.removeAll { $0.id == project.id } }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this project. Its repos are untouched.")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if project.repos.isEmpty {
                    Text("No repos yet").foregroundStyle(.orange)
                }
                ForEach(project.repos, id: \.self) { repo in
                    HStack(spacing: 2) {
                        Text(repo.split(separator: "/").last.map(String.init) ?? repo)
                        Button {
                            update(project.id) { $0.repos.removeAll { $0 == repo } }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    .help(repo)
                }
                Menu {
                    ForEach(repos.filter { !project.repos.contains($0) }, id: \.self) { repo in
                        Button(repo) { update(project.id) { $0.repos.append(repo) } }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a repo to this project")
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
    }

    private func update(_ id: UUID, _ change: (inout RepoProject) -> Void) {
        configs.update(org) { config in
            guard let index = config.repoProjects.firstIndex(where: { $0.id == id }) else { return }
            change(&config.repoProjects[index])
        }
    }
}
