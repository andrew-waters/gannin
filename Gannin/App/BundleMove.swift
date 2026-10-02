import Foundation

/// Gannin was `dev.andon.getgannin` before it was `dev.andon.gannin`. On
/// the first launch under the new ID, what was kept under the old one comes
/// across: its preferences, its folder in Application Support, and the
/// GitHub token (the keychain may ask once). The store is in the shared
/// Application Support folder, so it needs no moving. Nothing old is
/// deleted.
enum BundleMove {
    static let oldIdentifier = "dev.andon.getgannin"
    private static let doneKey = "movedFromGetgannin"

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
        let support = URL.applicationSupportDirectory
        if let current = Bundle.main.bundleIdentifier {
            let from = support.appending(path: oldIdentifier, directoryHint: .isDirectory)
            let to = support.appending(path: current, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) {
                try? FileManager.default.copyItem(at: from, to: to)
            }
        }
        Keychain.moveToken(fromService: "\(oldIdentifier).github")
        defaults.set(true, forKey: doneKey)
    }
}
