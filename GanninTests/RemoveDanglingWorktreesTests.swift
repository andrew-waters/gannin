import Foundation
import Testing
@testable import Gannin

/// Finish and Clean Up on worktrees whose git dir is gone.
struct RemoveDanglingWorktreesTests {
    private func folder() -> String {
        FileManager.default.temporaryDirectory.appending(path: "gannin-dangling-\(UUID().uuidString)").path
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    private func write(_ path: String, _ text: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func run(_ folder: String, inHarness: Bool) -> Shell.Result {
        Shell.run(SessionStore.removeDanglingWorktrees(folder: folder, inHarness: inHarness), .local)
    }

    @Test func aCheckoutWithNoGitDirIsRemovedWithItsFiles() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/api/.git", "gitdir: \(root)/missing/.git/worktrees/api\n")
        try write(root + "/api/Sources/main.swift", "work")
        #expect(run(root, inHarness: true).ok)
        #expect(!exists(root + "/api"))
    }

    @Test func aWorktreeWithNoGitDirAndNothingElseIsRemoved() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/api/.git", "gitdir: \(root)/missing/.git/worktrees/api\n")
        #expect(run(root, inHarness: true).ok)
        #expect(!exists(root + "/api"))
    }

    @Test func aSingleWorktreeFolderIsRemovedToo() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/.git", "gitdir: \(root)-missing/.git/worktrees/api\n")
        #expect(run(SessionScript.quoted(root), inHarness: false).ok)
        #expect(!exists(root))
    }

    @Test func aWorktreeWhoseGitDirIsThereIsKept() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/clone/.git/worktrees/api", withIntermediateDirectories: true)
        try write(root + "/issue/api/.git", "gitdir: \(root)/clone/.git/worktrees/api\n")
        #expect(run(root + "/issue", inHarness: true).ok)
        #expect(exists(root + "/issue/api/.git"))
    }

    /// As `worktree.useRelativePaths` writes it: from the worktree's folder.
    @Test func aRelativeGitDirIsFollowedFromTheWorktree() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/clone/.git/worktrees/api", withIntermediateDirectories: true)
        try write(root + "/issue/api/.git", "gitdir: ../../clone/.git/worktrees/api\n")
        try write(root + "/issue/gone/.git", "gitdir: ../../clone/.git/worktrees/gone\n")
        try write(root + "/issue/gone/main.swift", "work")
        #expect(run(root + "/issue", inHarness: true).ok)
        #expect(exists(root + "/issue/api/.git"))
        #expect(!exists(root + "/issue/gone"))
    }

    @Test func aGitDirThatCantBeEnteredIsntTreatedAsMissing() throws {
        let root = folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/clone/.git/worktrees/api")
            try? FileManager.default.removeItem(atPath: root)
        }
        try FileManager.default.createDirectory(atPath: root + "/clone/.git/worktrees/api", withIntermediateDirectories: true)
        try write(root + "/issue/api/.git", "gitdir: \(root)/clone/.git/worktrees/api\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/clone/.git/worktrees/api")
        #expect(run(root + "/issue", inHarness: true).ok)
        #expect(exists(root + "/issue/api/.git"))
    }

    @Test func aGitFileWithNoGitDirLineIsLeftAlone() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/empty/.git", "")
        try write(root + "/other/.git", "not a gitdir line\n")
        #expect(run(root, inHarness: true).ok)
        #expect(exists(root + "/empty/.git"))
        #expect(exists(root + "/other/.git"))
    }

    @Test func aLinkToACloneIsUnlinkedAndTheCloneKept() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/clone/.git", withIntermediateDirectories: true)
        try write(root + "/clone/main.swift", "mine")
        try FileManager.default.createDirectory(atPath: root + "/issue", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/issue/api", withDestinationPath: root + "/clone")
        #expect(run(root + "/issue", inHarness: true).ok)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/issue/api")) == nil)
        #expect(exists(root + "/clone/main.swift"))
        #expect(exists(root + "/clone/.git"))
    }

    @Test func aFolderWithNoGitFileIsLeftAlone() throws {
        let root = folder()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/notes/todo.md", "mine")
        #expect(run(root, inHarness: true).ok)
        #expect(exists(root + "/notes/todo.md"))
    }
}
