import Combine
import Sparkle
import SwiftUI

/// Sparkle's updater, for the Mac app distributed outside the App Store:
/// it reads gannin.ai's appcast (`SUFeedURL` and `SUPublicEDKey` in
/// `Info.plist`), asks on the second launch whether it may check by
/// itself, and offers new releases signed with Gannin's key. Development
/// builds (version 0.0.0) don't check by themselves, or every release
/// would be offered over them.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false

    private init() {
        let isRelease = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) != "0.0.0"
        controller = SPUStandardUpdaterController(startingUpdater: isRelease, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Gannin › Check for Updates, disabled while a check is under way.
struct CheckForUpdatesCommand: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
