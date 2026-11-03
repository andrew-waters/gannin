import Foundation

/// The highlight.js language a file's diff is coloured in, chosen from its
/// path alone.
nonisolated enum DiffLanguage {
    /// Not a highlight.js language: a component is split into sections, each
    /// in its own (`VueSections`).
    static let vue = "vue"

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
        "vue": DiffLanguage.vue,
        "sh": "bash", "bash": "bash", "zsh": "bash",
    ]

    private static let byFilename: [String: String] = [
        "dockerfile": "dockerfile",
        ".bashrc": "bash", ".zshrc": "bash", ".bash_profile": "bash", ".zprofile": "bash",
    ]

    /// Every highlight.js language a file can be coloured in.
    static var allLanguages: Set<String> {
        Set(byExtension.values).union(byFilename.values).subtracting([vue]).union(VueSections.languages)
    }

    /// The language for a path, or nil when it isn't in the supported set.
    static func name(forPath path: String) -> String? {
        let file = (path as NSString).lastPathComponent.lowercased()
        if let language = byFilename[file] { return language }
        if file.hasPrefix("dockerfile.") { return "dockerfile" }
        let ext = (file as NSString).pathExtension
        return ext.isEmpty ? nil : byExtension[ext]
    }
}
