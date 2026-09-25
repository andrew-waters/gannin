import SwiftUI

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 22

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Overlapping avatars for a small group of people.
struct AvatarStack: View {
    let people: [Person]
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: -size / 3) {
            ForEach(people.prefix(4)) { person in
                Avatar(url: person.avatarUrl, size: size)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    .help(person.displayName)
            }
        }
    }
}

struct CountBadge: View {
    let count: Int
    let systemImage: String
    let help: String
    var tint: Color = .secondary

    var body: some View {
        Label("\(count)", systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.monospacedDigit())
            .foregroundStyle(count == 0 ? Color.secondary.opacity(0.5) : tint)
            .help(help)
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct LabelChip: View {
    let label: IssueLabel

    var body: some View {
        Pill(text: label.name, color: Color(hex: label.color) ?? .secondary)
    }
}

extension PullRequest {
    var statusText: String {
        if isMerged { return "Merged" }
        if state == "CLOSED" { return "Closed" }
        if isDraft { return "Draft" }
        switch reviewDecision {
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        case .reviewRequired, nil: return "In review"
        }
    }

    var statusColor: Color {
        if isMerged { return .purple }
        if state == "CLOSED" { return .red }
        if isDraft { return .gray }
        switch reviewDecision {
        case .approved: return .green
        case .changesRequested: return .orange
        case .reviewRequired, nil: return .blue
        }
    }
}

extension LinkedItem {
    var stateColor: Color {
        switch state {
        case "MERGED": .purple
        case "CLOSED": .red
        default: .green
        }
    }
}

extension Color {
    /// Parses GitHub's six-digit hex label colours.
    init?(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

struct RelativeDate: View {
    let date: Date

    var body: some View {
        Text(date, format: .relative(presentation: .named))
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }
}

/// One-line notice with the full text in a tooltip and an optional retry.
struct Banner: View {
    let message: String
    let systemImage: String
    let tint: Color
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(message)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let retry {
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .help(message)
    }
}
