import Foundation
import Testing
@testable import Gannin

/// `SessionFileWriter` keeps the disk off the main actor without reordering
/// what it was asked to do.
@MainActor
struct SessionFileWriterTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "SessionFileWriterTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    private func text(at url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    /// Waits up to five seconds for `condition`, for work that finishes on a
    /// background queue `drain()` doesn't cover.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func theNewestWriteWins() {
        defer { clean() }
        let writer = SessionFileWriter()
        let file = folder.appending(path: "Sessions.json")
        for number in 1...20 { writer.write(Data("\(number)".utf8), to: file) }
        writer.drain()
        #expect(text(at: file) == "20")
    }

    @Test func aWriteMakesItsFolder() {
        defer { clean() }
        let writer = SessionFileWriter()
        let file = folder.appending(path: "nested/Sessions.json")
        writer.write(Data("x".utf8), to: file)
        writer.drain()
        #expect(text(at: file) == "x")
    }

    @Test func aFolderGoesAfterTheWritesBeforeIt() async {
        defer { clean() }
        let writer = SessionFileWriter()
        let session = folder.appending(path: "session", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try? Data("transcript".utf8).write(to: session.appending(path: "log"))
        // A write inside the folder, then its removal: were they reordered,
        // the write would bring the folder back.
        writer.write(Data("x".utf8), to: session.appending(path: "state"))
        writer.removeFolder(session)
        let gone = await eventually { !FileManager.default.fileExists(atPath: session.path) }
        #expect(gone)
    }

    @Test func drainDoesNotWaitForAFolderToBeRemoved() {
        defer { clean() }
        let writer = SessionFileWriter()
        let file = folder.appending(path: "Sessions.json")
        writer.write(Data("x".utf8), to: file)
        writer.removeFolder(folder.appending(path: "other", directoryHint: .isDirectory))
        writer.drain()
        #expect(text(at: file) == "x")
    }
}
