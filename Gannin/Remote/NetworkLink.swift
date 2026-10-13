import Foundation
import Network

/// A `RemoteLink` over an `NWConnection` the listener accepted. It reports when the
/// connection is ready (the TLS handshake is done, so the phone's key can be read), then
/// the bytes that arrive, and when it ends.
@MainActor
final class NetworkLink: RemoteLink {
    private let connection: NWConnection
    private var receiving = false
    var onReady: (@MainActor () -> Void)?
    var onData: (@MainActor (Data) -> Void)?
    var onClose: (@MainActor () -> Void)?

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.onReady?()
                case .failed, .cancelled: self?.onClose?()
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// Starts reading, once the host has decided to keep the connection.
    func startReceiving() {
        guard !receiving else { return }
        receiving = true
        receive()
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.onData?(data) }
                if isComplete || error != nil {
                    self.onClose?()
                } else {
                    self.receive()
                }
            }
        }
    }
}
