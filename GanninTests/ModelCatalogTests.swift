import Foundation
import Testing
@testable import Gannin

/// The models a picker offers beyond Gannin's list: named from their IDs,
/// and found in this Mac's Claude Code transcripts.
@MainActor
struct ModelCatalogTests {
    @Test func anUnlistedModelIsNamedFromItsID() {
        #expect(AIModel.named("claude-opus-4-7").name == "Claude Opus 4.7")
        #expect(AIModel.named("claude-haiku-4-5-20251001").name == "Claude Haiku 4.5")
        #expect(AIModel.named("claude-sonnet-5").name == "Claude Sonnet 5")
        // Anything else is shown as written.
        #expect(AIModel.named("opus[1m]").name == "opus[1m]")
        #expect(AIModel.named("claude-3-5-sonnet-20241022").name == "claude-3-5-sonnet-20241022")
    }

    @Test func transcriptsGiveTheirModelsNewestFirst() throws {
        let text = """
            {"message":{"model":"claude-sonnet-5-5","content":[]}}
            {"message":{"model":"<synthetic>"}}
            {"message":{"model":"claude-opus-5-5"}}
            {"message":{"model":"claude-sonnet-5-5"}}
            """
        #expect(ClaudeCodeProvider.modelIDs(in: text) == ["claude-sonnet-5-5", "claude-opus-5-5"])

        let projects = FileManager.default.temporaryDirectory.appending(path: "ModelCatalogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: projects) }
        let older = projects.appending(path: "a/1.jsonl")
        let newer = projects.appending(path: "b/2.jsonl")
        for url in [older, newer] { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        try Data(#"{"model":"claude-haiku-5-5"}"#.utf8).write(to: older)
        try Data(#"{"model":"claude-fable-5-1"}"#.utf8).write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)
        #expect(ClaudeCodeProvider.modelsSeen(in: projects) == ["claude-fable-5-1", "claude-haiku-5-5"])
        #expect(ClaudeCodeProvider.modelsSeen(in: projects, limit: 1) == ["claude-fable-5-1"])
    }
}
