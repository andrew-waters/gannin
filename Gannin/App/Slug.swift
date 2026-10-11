import Foundation

/// A branch name or path segment from free text: ASCII letters and numbers,
/// lowercased and hyphenated, without cutting a word in half past `limit`
/// characters.
enum Slug {
    static func make(_ text: String, limit: Int) -> String {
        let words = String(text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : " " }).split(separator: " ")
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? String(word) : "\(slug)-\(word)"
            if next.count > limit { break }
            slug = next
        }
        return slug
    }
}
