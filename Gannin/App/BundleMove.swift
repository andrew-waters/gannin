import Foundation

/// Gannin was `dev.andon.getgannin` before it was `dev.andon.gannin`. On
/// the first launch under the new ID, what was kept under the old one comes
/// across: its preferences, its folder in Application Support, and the
/// GitHub token (the keychain may ask once). The store is in the shared
/// Application Support folder, so it needs no moving. Nothing old is
/// deleted.
enum BundleMove {
    nonisolated static let oldIdentifier = "dev.andon.getgannin"
    nonisolated private static let doneKey = "movedFromGetgannin"

    /// Moves the preferences and the folder, which must be there before
    /// anything reads them. `finish` moves the token and marks the move
    /// done, so this repeats until it has.
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey), Bundle.main.bundleIdentifier != oldIdentifier else { return }
        // Preferences, when this ID has none of its own yet.
        if let old = defaults.persistentDomain(forName: oldIdentifier), !old.isEmpty,
           let current = Bundle.main.bundleIdentifier {
            let mine = defaults.persistentDomain(forName: current) ?? [:]
            defaults.setPersistentDomain(old.merging(mine) { _, new in new }, forName: current)
        }
        // Sessions, pending harness changes and the issue text index.
        let support = AppPaths.support
        if let current = Bundle.main.bundleIdentifier {
            let from = support.appending(path: oldIdentifier, directoryHint: .isDirectory)
            let to = support.appending(path: current, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
                try? FileManager.default.copyItem(at: from, to: to)
            }
        }
    }

    /// Moves the token and marks the move done. The keychain may ask to
    /// allow the old item, so this runs off the main actor, and before the
    /// token is read (`AuthStore.loadToken`).
    @concurrent static func finish() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey), Bundle.main.bundleIdentifier != oldIdentifier else { return }
        Keychain.moveToken(fromService: "\(oldIdentifier).github")
        defaults.set(true, forKey: doneKey)
    }
}
