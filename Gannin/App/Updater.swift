import Combine
import Sparkle
import SwiftUI

/// Sparkle's updater, for the Mac app distributed outside the App Store:
/// it reads gannin.ai's appcast (`SUFeedURL` and `SUPublicEDKey` in
/// `Info.plist`), asks on the second launch whether it may check by
/// itself, and offers new releases signed with Gannin's key. Development
/// builds (version 0.0.0) check only when asked, from Check for Updates, so
/// Sparkle can be tried in one without every release being offered over it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    private let delegate: UpdaterDelegate
    @Published private(set) var canCheckForUpdates = false

    private init() {
        let isRelease = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) != "0.0.0"
        delegate = UpdaterDelegate(isRelease: isRelease)
        controller = SPUStandardUpdaterController(startingUpdater: !NetworkGate.isSealed, updaterDelegate: delegate, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Keeps a development build from checking by itself or asking whether it
/// may; a check asked for from the menu still runs.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    let isRelease: Bool

    init(isRelease: Bool) { self.isRelease = isRelease }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard isRelease || updateCheck == .updates else {
            throw CocoaError(.userCancelled)
        }
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { isRelease }
}

/// Gannin › Check for Updates, disabled while a check is under way.
struct CheckForUpdatesCommand: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
