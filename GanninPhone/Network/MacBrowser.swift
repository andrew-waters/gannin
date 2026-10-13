import Foundation
import GanninRemote
import Network
import Observation

/// Looks for Macs advertising Gannin on the local network.
@MainActor
@Observable
final class MacBrowser {
    /// Advertised name to where to reach it.
    private(set) var endpoints: [String: NWEndpoint] = [:]
    /// Set while the system won't let the app browse, usually Local Network being off.
    private(set) var problem: String?
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: RemoteProtocol.serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.problem = nil
                case .waiting, .failed:
                    self?.problem = "Can't look for Macs. Check that Local Network is allowed for Gannin Remote in Settings."
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [(String, NWEndpoint)] = []
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint { found.append((name, result.endpoint)) }
            }
            let endpoints = Dictionary(found, uniquingKeysWith: { first, _ in first })
            Task { @MainActor in self?.endpoints = endpoints }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        endpoints = [:]
    }

    func endpoint(for name: String) -> NWEndpoint? { endpoints[name] }
}
