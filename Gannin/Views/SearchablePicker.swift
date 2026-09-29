import SwiftUI

/// One entry in a `SearchableList`: a value (nil for a None or Default
/// entry), what it's called, and the section it's listed under.
struct SearchableChoice: Identifiable, Hashable {
    let value: String?
    let title: String
    var section: String?

    var id: String { value ?? "\u{0}" }
}

/// A picker for long lists, like the org's repos: its button shows the
/// choice and opens a popover with a search field above the list. Typing
/// filters by any part of the name, the arrows move, Return picks and Esc
/// closes. Mac menus only jump by the start of a name, which is no help when
/// every repo starts with the org.
struct SearchablePicker: View {
    let choices: [SearchableChoice]
    let selection: String?
    var prompt = "Search"
    /// Still fetching the list: shown under what's there so far.
    var isLoading = false
    let onPick: (String?) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(choices.first { $0.value == selection }?.title ?? selection ?? "None")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SearchableList(choices: choices, selection: selection, prompt: prompt, isLoading: isLoading) { value in
                isPresented = false
                onPick(value)
            }
        }
    }
}

/// The popover's content, for a button of any kind to present.
struct SearchableList: View {
    let choices: [SearchableChoice]
    let selection: String?
    var prompt = "Search"
    var isLoading = false
    let onPick: (String?) -> Void

    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var isSearching: Bool

    var body: some View {
        let matches = matches
        VStack(spacing: 0) {
            searchField(matches)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections(matches), id: \.title) { section in
                            if let title = section.title {
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 13)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)
                            }
                            ForEach(section.choices) { choice in
                                row(choice)
                                    .id(choice.id)
                            }
                        }
                        if matches.isEmpty && !isLoading {
                            Text("No matches")
                                .foregroundStyle(.secondary)
                                .padding(10)
                        }
                        if isLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Loading").foregroundStyle(.secondary)
                            }
                            .padding(10)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .frame(width: 320)
        .frame(minHeight: 120, maxHeight: 380)
        // A Form's trailing alignment would otherwise carry into the field.
        .multilineTextAlignment(.leading)
        .onAppear {
            highlighted = selection.map { SearchableChoice(value: $0, title: "").id } ?? choices.first?.id
            isSearching = true
        }
        .onChange(of: query) {
            // Typing puts the best match first under the keyboard.
            highlighted = self.matches.first?.id
        }
    }

    /// The Mac's search field: a capsule with a magnifying glass, and a
    /// clear button once there's something to clear.
    private func searchField(_ matches: [SearchableChoice]) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .focused($isSearching)
                .onSubmit { pickHighlighted(in: matches) }
                .onKeyPress(.downArrow) { move(1, in: matches) }
                .onKeyPress(.upArrow) { move(-1, in: matches) }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.7), in: Capsule())
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func row(_ choice: SearchableChoice) -> some View {
        let isHighlighted = choice.id == highlighted
        return Button {
            onPick(choice.value)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(choice.value == selection ? 1 : 0)
                Text(choice.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .background(isHighlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = choice.id } }
    }

    /// Everything, or those whose name holds the query: names whose last
    /// part (the repo, not the org) starts with it first.
    private var matches: [SearchableChoice] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return choices }
        let found = choices.filter { $0.title.localizedCaseInsensitiveContains(query) }
        let starts = found.filter { choice in
            let name = choice.title.split(separator: "/").last.map(String.init) ?? choice.title
            return name.lowercased().hasPrefix(query.lowercased())
        }
        let startIDs = Set(starts.map(\.id))
        return starts + found.filter { !startIDs.contains($0.id) }
    }

    /// Consecutive choices with the same section, in order. While searching
    /// the headings go, so the best match can be first.
    private func sections(_ matches: [SearchableChoice]) -> [(title: String?, choices: [SearchableChoice])] {
        guard query.isEmpty else { return [(nil, matches)] }
        var result: [(title: String?, choices: [SearchableChoice])] = []
        for choice in matches {
            if let last = result.last, last.title == choice.section {
                result[result.count - 1].choices.append(choice)
            } else {
                result.append((choice.section, [choice]))
            }
        }
        return result
    }

    private func move(_ step: Int, in matches: [SearchableChoice]) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        let current = matches.firstIndex { $0.id == highlighted } ?? (step > 0 ? -1 : matches.count)
        highlighted = matches[min(max(current + step, 0), matches.count - 1)].id
        return .handled
    }

    private func pickHighlighted(in matches: [SearchableChoice]) {
        if let choice = matches.first(where: { $0.id == highlighted }) ?? matches.first {
            onPick(choice.value)
        }
    }
}
