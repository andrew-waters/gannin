import Foundation
import GanninRemote
import Observation

/// A phone this Mac has paired with, known by the fingerprint of its key.
nonisolated struct RemotePhone: Codable, Identifiable, Hashable {
    var fingerprint: String
    var name: String
    var pairedAt: Date
    var lastSeen: Date?

    var id: String { fingerprint }
}

/// The phones allowed to connect. Kept in `UserDefaults`: a fingerprint is public, and
/// anything able to change this could do whatever it liked to the Mac without it.
@Observable
final class PairedPhones {
    static let key = "remote.pairedPhones"

    private(set) var phones: [RemotePhone]
    /// Called after a phone is revoked, so its open connections close.
    @ObservationIgnored var onRevoke: ((RemotePhone) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        phones = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([RemotePhone].self, from: $0) } ?? []
    }

    func phone(for fingerprint: Data) -> RemotePhone? {
        phones.first { $0.fingerprint == fingerprint.hexString }
    }

    func isPaired(_ fingerprint: Data) -> Bool { phone(for: fingerprint) != nil }

    /// Adds a phone, or renames one already paired under the same key.
    @discardableResult
    func add(name: String, fingerprint: Data, now: Date = .now) -> RemotePhone {
        let phone = RemotePhone(fingerprint: fingerprint.hexString, name: name, pairedAt: now, lastSeen: now)
        phones.removeAll { $0.fingerprint == phone.fingerprint }
        phones.append(phone)
        save()
        return phone
    }

    func noteSeen(_ fingerprint: Data, now: Date = .now) {
        guard let index = phones.firstIndex(where: { $0.fingerprint == fingerprint.hexString }) else { return }
        phones[index].lastSeen = now
        save()
    }

    func revoke(_ phone: RemotePhone) {
        guard phones.contains(where: { $0.id == phone.id }) else { return }
        phones.removeAll { $0.id == phone.id }
        save()
        onRevoke?(phone)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(phones), forKey: Self.key)
    }
}
