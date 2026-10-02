import SwiftUI

/// A search snippet's matching words (marked `[[` and `]]` by the index)
/// in bold, for Find and add.
enum PrioritisationSearchHighlight {
    /// The snippet with its matching words in bold.
    static func highlighted(_ snippet: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(snippet.replacingOccurrences(of: "\n", with: " "))
        while let open = rest.range(of: "[[") {
            result += AttributedString(String(rest[..<open.lowerBound]))
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else {
                rest = after
                break
            }
            var match = AttributedString(String(after[..<close.lowerBound]))
            match.font = .caption.weight(.bold)
            match.foregroundColor = .primary
            result += match
            rest = after[close.upperBound...]
        }
        result += AttributedString(String(rest))
        return result
    }
}
