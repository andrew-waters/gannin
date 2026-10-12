import Foundation

/// The highlight.js language a file's diff is coloured in, chosen from its
/// path alone.
nonisolated enum DiffLanguage {
    private static let byExtension: [String: String] = [
        "swift": "swift",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "go": "go",
        "php": "php",
        "py": "python", "pyi": "python",
        "json": "json", "jsonc": "json",
        "dockerfile": "dockerfile",
        "yml": "yaml", "yaml": "yaml",
        "md": "markdown", "markdown": "markdown",
        "sh": "bash", "bash": "bash", "zsh": "bash",
    ]

    private static let byFilename: [String: String] = [
        "dockerfile": "dockerfile",
        ".bashrc": "bash", ".zshrc": "bash", ".bash_profile": "bash", ".zprofile": "bash",
    ]

    static var allLanguages: Set<String> { Set(byExtension.values).union(byFilename.values) }

    /// The language for a path, or nil when it isn't in the supported set.
    static func name(forPath path: String) -> String? {
        let file = (path as NSString).lastPathComponent.lowercased()
        if let language = byFilename[file] { return language }
        if file.hasPrefix("dockerfile.") { return "dockerfile" }
        let ext = (file as NSString).pathExtension
        return ext.isEmpty ? nil : byExtension[ext]
    }
}
