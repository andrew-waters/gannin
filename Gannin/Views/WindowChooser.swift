import SwiftUI

/// Where a main window is: its org and the project it works in (nil for home).
struct WindowPlace: Equatable {
    let org: String
    var workspace: String?
}

extension FocusedValues {
    /// The focused main window's place, for New Window and New Tab to start from.
    @Entry var windowPlace: WindowPlace?
}

/// File › New Window and New Tab: a window that asks which org and project
/// to open on, unless Settings › General says not to.
struct BlankWindowRequest {
    /// The window it was opened from; nil when none was focused.
    let from: WindowPlace?

    /// Set when Settings › General › Ask which organisation and project new
    /// windows open is on.
    static let asksKey = "asksWhereNewWindowsOpen"
}

/// A new window's question: which org and project to open on. Starts on the
/// window it was opened from, so Return copies it.
struct WindowChooser: View {
    @Environment(OrgStore.self) private var orgs
    @Environment(OrgConfigStore.self) private var configs
    /// The window it was opened from: what it starts on, and what Esc opens.
    let from: WindowPlace?
    /// What it starts on with no window to copy: the last org picked.
    let fallback: WindowPlace?
    let open: (WindowPlace) -> Void
    private var start: WindowPlace? { from ?? fallback }
    @State private var org: String?
    @State private var workspace: String?

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(systemName: "macwindow.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Open This Window On")
                    .font(.title2.weight(.semibold))
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Organisation")
                        .gridColumnAlignment(.trailing)
                    orgPicker
                }
                if let org, !projects(org).isEmpty {
                    GridRow {
                        Text("Project")
                        projectPicker(org)
                    }
                }
            }
            HStack {
                if let from {
                    Button("Same as Last Window") { open(from) }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Open") {
                    if let org { open(WindowPlace(org: org, workspace: workspace)) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(org == nil)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: start, initial: true) {
            guard org == nil, let start else { return }
            org = start.org
            workspace = start.workspace
        }
        .onChange(of: orgs.orgs, initial: true) {
            // Nothing to ask with one account and no projects.
            if orgs.orgs.count == 1, let only = orgs.orgs.first, projects(only.login).isEmpty {
                open(WindowPlace(org: only.login))
            }
        }
    }

    private func projects(_ org: String) -> [RepoProject] {
        configs.baseConfig(for: org).repoProjects
    }

    private var orgPicker: some View {
        Picker("Organisation", selection: Binding(get: { org }, set: { picked in
            org = picked
            workspace = picked == start?.org ? start?.workspace : picked.flatMap(MainView.lastWorkspace(for:))
        })) {
            if org == nil { Text("Choose an Organisation").tag(String?.none) }
            if !orgs.starredOrgs.isEmpty {
                Section("Starred") {
                    ForEach(orgs.starredOrgs) { Text($0.displayName).tag(Optional($0.login)) }
                }
            }
            let personal = orgs.orgs.filter { $0.isPersonal && !orgs.isStarred($0) }
            if !personal.isEmpty {
                Section("Personal") {
                    ForEach(personal) { Text("\($0.displayName) (\($0.login))").tag(Optional($0.login)) }
                }
            }
            Section(orgs.starredOrgs.isEmpty ? "Organisations" : "Other Organisations") {
                ForEach(orgs.orgs.filter { !orgs.isStarred($0) && !$0.isPersonal }) { Text($0.displayName).tag(Optional($0.login)) }
            }
        }
        .labelsHidden()
        .frame(width: 260)
    }

    /// The org's projects; no pick is home, the first.
    private func projectPicker(_ org: String) -> some View {
        let projects = projects(org)
        let selected = workspace.flatMap { id in projects.first { $0.id == id } } ?? projects.first
        return Picker("Project", selection: Binding(get: { selected?.id }, set: { workspace = $0 })) {
            ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
        }
        .labelsHidden()
        .frame(width: 260)
    }
}
