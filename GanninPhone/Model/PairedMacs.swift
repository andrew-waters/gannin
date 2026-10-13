import Foundation
import Observation

/// A Mac this phone has paired with, known by the fingerprint of its key. `name` is the
/// name it advertises on the network, which is how it's found again.
nonisolated struct PairedMac: Codable, Identifiable, Hashable {
    var fingerprint: String
    var name: String
    var pairedAt: Date

    var id: String { fingerprint }
}

/// The Macs this phone can control, kept on this phone only. A fingerprint is public, so
/// this isn't secret: what keeps another Mac out is the pinned key, not this list.
@MainActor
@Observable
final class PairedMacs {
    static let key = "phone.pairedMacs"

    private(set) var macs: [PairedMac]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        macs = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([PairedMac].self, from: $0) } ?? []
    }

    func add(_ mac: PairedMac) {
        macs.removeAll { $0.id == mac.id }
        macs.append(mac)
        save()
    }

    func remove(_ mac: PairedMac) {
        macs.removeAll { $0.id == mac.id }
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(macs), forKey: Self.key)
    }
}
