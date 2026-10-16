import Foundation
import Testing
@testable import Gannin

struct BoardCacheFilesTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "BoardCacheFilesTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var cache: BoardCache {
        let board = Board(id: "b", number: 1, title: "Board", url: URL(string: "https://example.com")!, fields: [], views: [])
        return BoardCache(board: board, fetchedAt: Date(timeIntervalSince1970: 1_760_000_000))
    }

    private func prepare() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "board.json")
    }

    @Test func writtenCacheReadsBack() throws {
        let url = try prepare()
        let files = BoardCacheFiles()
        files.write(cache, to: url, generation: files.generation)
        #expect(BoardCacheFiles.read(url)?.board.title == "Board")
    }

    @Test func writeFromBeforeAResetIsSkipped() throws {
        let url = try prepare()
        let files = BoardCacheFiles()
        let before = files.generation
        files.reset(removing: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files.write(cache, to: url, generation: before)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func writeAfterAResetLands() throws {
        let url = try prepare()
        let files = BoardCacheFiles()
        files.reset(removing: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files.write(cache, to: url, generation: files.generation)
        #expect(BoardCacheFiles.read(url) != nil)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func resetDeletesTheFolder() throws {
        let url = try prepare()
        let files = BoardCacheFiles()
        files.write(cache, to: url, generation: files.generation)
        files.reset(removing: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func missingOrBrokenFileReadsAsNil() throws {
        let url = try prepare()
        #expect(BoardCacheFiles.read(url) == nil)
        try Data("not json".utf8).write(to: url)
        #expect(BoardCacheFiles.read(url) == nil)
        try? FileManager.default.removeItem(at: directory)
    }
}
