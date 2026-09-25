import Foundation
import Observation

/// In-memory cache of issue and PR detail, keyed by GraphQL node ID.
@Observable
final class DetailStore {
    private(set) var details: [String: ItemDetail] = [:]
    private(set) var errors: [String: String] = [:]
    private var loading: Set<String> = []

    private let auth: AuthStore

    init(auth: AuthStore) {
        self.auth = auth
    }

    func detail(for id: String) -> ItemDetail? { details[id] }

    func load(_ id: String, force: Bool = false) async {
        guard let api = auth.api, !loading.contains(id), force || details[id] == nil else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        do {
            if let detail = try await api.itemDetail(id: id) {
                details[id] = detail
            }
            errors[id] = nil
        } catch is CancellationError {
        } catch APIError.unauthorized {
            auth.signOut()
        } catch {
            errors[id] = error.localizedDescription
        }
    }

    func clear() {
        details = [:]
        errors = [:]
    }
}
