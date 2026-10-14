import Foundation
import Testing
@testable import Gannin

struct AppPathsTests {
    /// The app's sources, found from this file: tests run hosted in the app,
    /// on the machine that built it.
    private static let sources = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Gannin", directoryHint: .isDirectory)

    /// A store reading Application Support by itself would show the real
    /// app's data in the demo build, or overwrite it.
    @Test func onlyAppPathsReadsApplicationSupport() throws {
        try #require(FileManager.default.fileExists(atPath: Self.sources.path))
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "AppPaths.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".applicationSupportDirectory") { offenders.append(url.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "Use AppPaths.support or AppPaths.own in \(offenders.joined(separator: ", "))")
    }

    @Test func ownFolderIsInsideSupport() {
        #expect(AppPaths.own.path.hasPrefix(AppPaths.support.path))
    }
}
