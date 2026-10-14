import Foundation

/// Where Gannin keeps its files. Every store roots its folder here rather
/// than at `URL.applicationSupportDirectory`, so the demo build (`DEMO`) can
/// point the whole app at a throwaway folder: a store reading Application
/// Support by itself would show or overwrite the real app's data there.
nonisolated enum AppPaths {
    /// The shared Application Support folder (the app isn't sandboxed); in
    /// the demo build, its own folder, emptied on launch (`DemoLaunch`).
    static let support: URL = {
        #if DEMO
        URL.applicationSupportDirectory
            .appending(path: identifier, directoryHint: .isDirectory)
            .appending(path: "Data", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory
        #endif
    }()

    /// Gannin's own folder in it, by bundle ID, for what shouldn't sit
    /// loose in the shared folder (sessions, routines, pending harness
    /// changes).
    static var own: URL { support.appending(path: identifier, directoryHint: .isDirectory) }

    private static var identifier: String { Bundle.main.bundleIdentifier ?? "dev.andon.gannin" }
}
