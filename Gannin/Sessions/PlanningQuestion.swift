import SwiftUI

/// How a planning session's questions are put to the room, picked on the
/// question itself and kept on this Mac.
enum PlanningQuestionStyle: String, CaseIterable, Identifiable {
    /// One big question, options lettered A, B, C to press, as Typeform.
    case focus
    /// A show of hands: votes counted per option, the most sent, as Slido.
    case poll
    /// A list to move through with the arrows and Return, as Raycast.
    case list
    /// The questions so far as a conversation, answers as chips beneath.
    case thread

    var id: Self { self }

    var name: String {
        switch self {
        case .focus: "One at a Time"
        case .poll: "Poll the Room"
        case .list: "Keyboard List"
        case .thread: "Conversation"
        }
    }

    var systemImage: String {
        switch self {
        case .focus: "rectangle.portrait.on.rectangle.portrait"
        case .poll: "chart.bar.xaxis"
        case .list: "list.bullet.indent"
        case .thread: "bubble.left.and.bubble.right"
        }
    }
}

/// The question to the room in a planning session, in the style picked.
/// Several questions at once are put one after another, and their answers
/// go back together, each paired with its question.
struct PlanningQuestionView: View {
    @Environment(SessionStore.self) private var sessions
    let session: CodeSession
    let question: SessionTranscript.Question
    /// What's been settled before, for the conversation style.
    var history: [PlanningState.Decision] = []
    /// Back from the first of these questions: the one settled before is
    /// put to the room again. Nil when there's none.
    var revisitLast: (() -> Void)? = nil
    @AppStorage("planningQuestionStyle") private var style: PlanningQuestionStyle = .focus

    /// Which of several questions is up.
    @State private var index = 0
    @State private var answers: [Int: String] = [:]
    /// Options ticked, for a question that takes several.
    @State private var picked: Set<Int> = []
    /// Hands up per option, polling.
    @State private var votes: [Int: Int] = [:]
    /// The option the arrows are on, in the list.
    @State private var highlighted = 0
    @State private var other = ""
    @FocusState private var keys: Bool

    private var item: SessionTranscript.Question.Item? {
        question.items.indices.contains(index) ? question.items[index] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if let item {
                switch style {
                case .focus: focus(item)
                case .poll: poll(item)
                case .list: list(item)
                case .thread: thread(item)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.45), lineWidth: 1.5) }
        .focusable()
        .focusEffectDisabled()
        .focused($keys)
        .onKeyPress(phases: .down, action: key)
        .onChange(of: question.id, initial: true) { reset(all: true) }
        .onChange(of: style) { reset(all: false) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            // Always first and always there, so it's where the hand goes.
            Button {
                if index > 0 {
                    index -= 1
                    reset(all: false)
                } else {
                    revisitLast?()
                }
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0 && revisitLast == nil)
            .help(index > 0 ? "Back to the question before; nothing's sent until the last is answered" : "Ask the question before again, to answer it differently")
            if let item, !item.header.isEmpty {
                Text(item.header)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
            }
            Text(question.items.count > 1 ? "Question \(index + 1) of \(question.items.count)" : "Question for the room")
                .font(.callout)
                .foregroundStyle(.secondary)
            if item?.multiSelect == true {
                Text("Pick any").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Style", selection: $style) {
                    ForEach(PlanningQuestionStyle.allCases) { style in
                        Label(style.name, systemImage: style.systemImage).tag(style)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(style.name, systemImage: style.systemImage)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("How questions are put to the room")
            Button("Skip") { sessions.sendKeys("\u{1B}", to: session.id) }
                .buttonStyle(.borderless)
                .help("Close the question without answering, to say something else below")
        }
    }

    private func title(_ item: SessionTranscript.Question.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.question)
                .font(.largeTitle.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            // Come back to: what was answered, kept unless it's changed.
            if let previous = answers[index] {
                Label("Answered: \(previous)", systemImage: "arrow.uturn.backward")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: One at a time

    private func focus(_ item: SessionTranscript.Question.Item) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            title(item)
            // Two to a row, the same height, so the room reads across.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(Array(item.options.enumerated()), id: \.offset) { number, option in
                    Button {
                        pick(number, in: item)
                    } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Text(letter(number))
                                .font(.headline.monospaced())
                                .frame(width: 30, height: 30)
                                .background(chosen(number) ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(chosen(number) ? .white : .primary)
                            VStack(alignment: .leading, spacing: 3) {
                                optionLabel(option)
                                    .font(.title2.weight(.semibold))
                                if !option.description.isEmpty {
                                    Text(option.description)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(chosen(number) ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(chosen(number) ? Color.accentColor : Color.separatorLine) }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(letter(number)): \(clean(option.label))")
                }
            }
            otherField(item, prompt: "Or type what the room said")
            footer(item, hint: "Press \(letter(0)) to \(letter(max(0, item.options.count - 1))) to answer.")
        }
    }

    // MARK: Poll

    private func poll(_ item: SessionTranscript.Question.Item) -> some View {
        let most = max(1, votes.values.max() ?? 0)
        let total = votes.values.reduce(0, +)
        return VStack(alignment: .leading, spacing: 20) {
            title(item)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(item.options.enumerated()), id: \.offset) { number, option in
                    let count = votes[number] ?? 0
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            optionLabel(option).fontWeight(.semibold)
                            if !option.description.isEmpty {
                                Text(option.description)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(width: 380, alignment: .leading)
                        GeometryReader { geometry in
                            RoundedRectangle(cornerRadius: 5)
                                .fill(count == most && count > 0 ? Color.accentColor : Color.accentColor.opacity(0.35))
                                .frame(width: max(4, geometry.size.width * CGFloat(count) / CGFloat(most)))
                                .animation(.snappy, value: count)
                        }
                        .frame(height: 22)
                        Text("\(count)")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                        HStack(spacing: 4) {
                            Button {
                                votes[number] = max(0, count - 1)
                            } label: {
                                Image(systemName: "minus")
                            }
                            .disabled(count == 0)
                            .accessibilityLabel("One fewer for \(clean(option.label))")
                            Button {
                                votes[number] = count + 1
                            } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("One more for \(clean(option.label))")
                        }
                        .controlSize(.large)
                    }
                }
            }
            otherField(item, prompt: "Or type what the room settled on")
            HStack {
                Text(total == 0 ? "Count hands with +, then send what won." : "\(total) \(total == 1 ? "vote" : "votes").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { votes = [:] }
                    .disabled(total == 0)
                Button(pollLabel(item)) { choose(pollAnswer(item)) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(total == 0)
            }
        }
    }

    /// The winner (or the tie), or every option with votes for a question
    /// that takes several, with the count so claude knows how split it was.
    private func pollAnswer(_ item: SessionTranscript.Question.Item) -> String {
        let total = votes.values.reduce(0, +)
        let counted = item.options.indices.filter { (votes[$0] ?? 0) > 0 }.sorted { (votes[$0] ?? 0) > (votes[$1] ?? 0) }
        let chosen = item.multiSelect ? counted : counted.filter { votes[$0] == votes[counted[0]] }
        let names = chosen.map { "\(clean(item.options[$0].label)) (\(votes[$0] ?? 0) of \(total))" }
        return chosen.count > 1 && !item.multiSelect ? "A tie: " + names.joined(separator: "; ") : names.joined(separator: "; ")
    }

    private func pollLabel(_ item: SessionTranscript.Question.Item) -> String {
        guard let top = item.options.indices.max(by: { (votes[$0] ?? 0) < (votes[$1] ?? 0) }), (votes[top] ?? 0) > 0 else { return "Send" }
        let tied = item.options.indices.filter { votes[$0] == votes[top] }.count > 1
        return item.multiSelect || tied ? "Send Votes" : "Send \"\(clean(item.options[top].label))\""
    }

    // MARK: Keyboard list

    private func list(_ item: SessionTranscript.Question.Item) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            title(item)
            VStack(spacing: 2) {
                ForEach(Array(item.options.enumerated()), id: \.offset) { number, option in
                    let on = number == highlighted
                    Button {
                        highlighted = number
                        pick(number, in: item)
                    } label: {
                        HStack(spacing: 10) {
                            if item.multiSelect {
                                Image(systemName: picked.contains(number) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(on ? .white : .secondary)
                            }
                            optionLabel(option)
                                .fontWeight(.medium)
                            Text(option.description)
                                .foregroundStyle(on ? Color.white.opacity(0.8) : .secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            if on {
                                Image(systemName: "return")
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .foregroundStyle(on ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help(option.description)
                    .onHover { if $0 { highlighted = number } }
                }
            }
            otherField(item, prompt: "Something else")
            footer(item, hint: "↑ ↓ to move, Return to pick.")
        }
    }

    // MARK: Conversation

    private func thread(_ item: SessionTranscript.Question.Item) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(history.suffix(4).enumerated()), id: \.offset) { _, decision in
                if let asked = decision.question {
                    bubble(asked, mine: false, faded: true)
                }
                bubble(decision.answer, mine: true, faded: true)
            }
            ForEach(question.items.indices.filter { $0 < index }, id: \.self) { earlier in
                bubble(question.items[earlier].question, mine: false, faded: true)
                bubble(answers[earlier] ?? "", mine: true, faded: true)
            }
            bubble(item.question, mine: false, faded: false)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(Array(item.options.enumerated()), id: \.offset) { number, option in
                    Button {
                        pick(number, in: item)
                    } label: {
                        optionLabel(option)
                            .fontWeight(.medium)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(chosen(number) ? Color.accentColor : Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(chosen(number) ? .white : .primary)
                            .overlay { Capsule().stroke(Color.accentColor.opacity(0.5)) }
                    }
                    .buttonStyle(.plain)
                    .help(option.description)
                }
            }
            otherField(item, prompt: "Reply with something else")
            footer(item, hint: "Hover an answer for more about it.")
        }
    }

    private func bubble(_ text: String, mine: Bool, faded: Bool) -> some View {
        HStack {
            if mine { Spacer(minLength: 80) }
            Text(text)
                .font(faded ? .callout : .title2.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(mine ? Color.accentColor.opacity(faded ? 0.5 : 1) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(mine ? .white : .primary)
                .opacity(faded && !mine ? 0.75 : 1)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !mine { Spacer(minLength: 80) }
        }
    }

    // MARK: Parts

    private func optionLabel(_ option: SessionTranscript.Question.Option) -> some View {
        HStack(spacing: 8) {
            Text(clean(option.label))
            if isRecommended(option) {
                Text("Recommended")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
    }

    private func otherField(_ item: SessionTranscript.Question.Item, prompt: String) -> some View {
        TextField(prompt, text: $other)
            .textFieldStyle(.roundedBorder)

            .onSubmit {
                let text = other.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { choose(text) }
            }
    }

    /// A hint, and Next or Send for a question that takes several answers.
    private func footer(_ item: SessionTranscript.Question.Item, hint: String) -> some View {
        HStack {
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if item.multiSelect {
                Button(index + 1 < question.items.count ? "Next" : "Send") {
                    choose(picked.sorted().map { clean(item.options[$0].label) }.joined(separator: "; "))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(picked.isEmpty)
            }
        }
    }

    // MARK: Answering

    private func pick(_ number: Int, in item: SessionTranscript.Question.Item) {
        guard item.options.indices.contains(number) else { return }
        if item.multiSelect {
            picked.formSymmetricDifference([number])
        } else {
            choose(clean(item.options[number].label))
        }
    }

    private func chosen(_ number: Int) -> Bool { picked.contains(number) }

    /// The answer to the question up: on to the next, or all of them sent.
    private func choose(_ answer: String) {
        answers[index] = answer
        if index + 1 < question.items.count {
            index += 1
            reset(all: false)
        } else {
            let pairs = question.items.enumerated().map { number, item in
                (item.question, answers[number] ?? "No preference: your call.")
            }
            sessions.answer(pairs, to: session.id)
        }
    }

    private func reset(all: Bool) {
        if all {
            index = 0
            answers = [:]
        }
        picked = []
        votes = [:]
        highlighted = item.flatMap { item in item.options.firstIndex(where: isRecommended) } ?? 0
        other = ""
        keys = true
    }

    /// Letters for one at a time, arrows and Return for the list; typing
    /// elsewhere (the other field, the comment bar) isn't caught.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard let item else { return .ignored }
        switch style {
        case .focus:
            guard press.modifiers.isEmpty, let char = press.characters.lowercased().first, let ascii = char.asciiValue, ascii >= 97 else { return .ignored }
            let number = Int(ascii) - 97
            guard item.options.indices.contains(number) else { return .ignored }
            pick(number, in: item)
            return .handled
        case .list:
            switch press.key {
            case .upArrow:
                highlighted = max(0, highlighted - 1)
                return .handled
            case .downArrow:
                highlighted = min(item.options.count - 1, highlighted + 1)
                return .handled
            case .return where press.modifiers.isEmpty:
                pick(highlighted, in: item)
                return .handled
            case .space where item.multiSelect:
                pick(highlighted, in: item)
                return .handled
            default:
                return .ignored
            }
        case .poll, .thread:
            return .ignored
        }
    }

    private func letter(_ number: Int) -> String {
        String(UnicodeScalar(UInt8(65 + min(number, 25))))
    }

    private func clean(_ label: String) -> String {
        label.replacingOccurrences(of: " (Recommended)", with: "")
    }

    private func isRecommended(_ option: SessionTranscript.Question.Option) -> Bool {
        option.label.localizedCaseInsensitiveContains("(recommended)")
    }
}
