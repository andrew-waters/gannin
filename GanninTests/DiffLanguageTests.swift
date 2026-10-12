import Highlighter
import Testing
@testable import Gannin

/// Which language a file's diff is highlighted in.
struct DiffLanguageTests {
    @Test(arguments: [
        ("Gannin/App/Gannin.swift", "swift"),
        ("web/src/app.tsx", "typescript"),
        ("web/src/app.js", "javascript"),
        ("cmd/main.go", "go"),
        ("src/Index.php", "php"),
        ("tools/run.py", "python"),
        ("package.json", "json"),
        (".github/workflows/ci.yml", "yaml"),
        ("README.md", "markdown"),
        ("scripts/relaunch.sh", "bash"),
        ("Dockerfile", "dockerfile"),
        ("build/Dockerfile", "dockerfile"),
    ])
    func supportedFiles(path: String, language: String) {
        #expect(DiffLanguage.name(forPath: path) == language)
    }

    @Test func extensionIsMatchedWithoutCase() {
        #expect(DiffLanguage.name(forPath: "Sources/Main.SWIFT") == "swift")
    }

    @Test(arguments: ["logo.png", "LICENSE", "notes.txt", "dir.swift/file", "Gannin.xcodeproj/project.pbxproj"])
    func otherFilesAreNotHighlighted(path: String) {
        #expect(DiffLanguage.name(forPath: path) == nil)
    }

    @Test func everyLanguageIsInTheBundledHighlighter() throws {
        let supported = Set(try #require(Highlighter())?.supportedLanguages() ?? [])
        for language in DiffLanguage.allLanguages { #expect(supported.contains(language), "\(language)") }
    }
}
