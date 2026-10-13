import Foundation
import GanninRemote
import Network
import Observation
import UIKit

/// One connection to one paired Mac: finds it, connects, subscribes, keeps what it sends
/// in `state`, reconnects when it drops, and carries the person's intents to it.
@MainActor
@Observable
final class RemoteClient {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case offline(String)
    }

    /// Silence this long means the Mac has gone, whatever TCP says (it heartbeats every 15 seconds).
    static let silenceSeconds: TimeInterval = 40
    static let answerSeconds = 15

    let mac: PairedMac
    private(set) var phase: Phase = .idle
    private(set) var state = RemoteSessionsState()

    @ObservationIgnored private let security: any ClientTransportSecurity
    @ObservationIgnored private let endpoint: @MainActor () -> NWEndpoint?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var decoder = FrameDecoder()
    @ObservationIgnored private var waiting: [String: CheckedContinuation<RemoteResult, Error>] = [:]
    @ObservationIgnored private var closeSignal: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastHeard = Date()
    @ObservationIgnored private var attempts = 0

    init(mac: PairedMac, security: any ClientTransportSecurity, endpoint: @escaping @MainActor () -> NWEndpoint?) {
        self.mac = mac
        self.security = security
        self.endpoint = endpoint
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [self] in await run() }
        watchdog = Task { [self] in await watchSilence() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        watchdog?.cancel()
        watchdog = nil
        connection?.cancel()
        connection = nil
        // The cancelled connection's own callback is ignored once it isn't the current one.
        closeSignal?.resume()
        closeSignal = nil
        failWaiting()
        phase = .idle
    }

    /// Carries an intent to the Mac and returns what it said. Throws when there's no
    /// connection or the Mac doesn't answer.
    func perform(_ intent: RemoteIntent, session: String, promptID: String? = nil) async throws -> RemoteResult {
        guard phase == .connected else { throw PhoneError.notConnected }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            send(.intent(id: id, session: session, promptID: promptID, intent: intent))
            Task { [self] in
                try? await Task.sleep(for: .seconds(Self.answerSeconds))
                waiting.removeValue(forKey: id)?.resume(throwing: PhoneError.timedOut)
            }
        }
    }

    // MARK: Connecting

    private func run() async {
        while !Task.isCancelled {
            if let endpoint = endpoint() {
                await connect(to: endpoint)
                guard !Task.isCancelled else { return }
                attempts += 1
                try? await Task.sleep(for: .seconds(min(30, 1 << min(attempts, 5))))
            } else {
                phase = .offline("Can't find \(mac.name) on this network.")
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Returns when the connection has ended.
    private func connect(to endpoint: NWEndpoint) async {
        phase = .connecting
        let parameters: NWParameters
        do {
            parameters = try security.parameters(forMac: mac)
        } catch {
            phase = .offline(error.localizedDescription)
            return
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        decoder = FrameDecoder()
        lastHeard = Date()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            closeSignal = done
            connection.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor in
                    guard let self, self.connection === connection else { return }
                    switch newState {
                    case .ready:
                        self.send(.hello(name: UIDevice.current.name))
                        self.send(.subscribe)
                        self.receive(on: connection)
                    case .failed(let error):
                        self.phase = .offline(error.localizedDescription)
                        connection.cancel()
                    case .cancelled:
                        self.ended()
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
        }
    }

    private func ended() {
        failWaiting()
        if case .offline = phase {} else if loop != nil { phase = .offline("Disconnected from \(mac.name).") }
        let signal = closeSignal
        closeSignal = nil
        connection = nil
        signal?.resume()
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let data, !data.isEmpty { self.handle(data) }
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection)
                }
            }
        }
    }

    private func handle(_ data: Data) {
        lastHeard = Date()
        decoder.append(data)
        do {
            while let payload = try decoder.next() {
                let message = try FrameCodec.decode(payload, as: ServerMessage.self)
                state.apply(message)
                switch message {
                case .hello:
                    phase = .connected
                    attempts = 0
                case .result(let id, let result):
                    waiting.removeValue(forKey: id)?.resume(returning: result)
                default:
                    break
                }
            }
        } catch FrameError.unsupportedVersion {
            phase = .offline("\(mac.name) runs a different version of Gannin. Update the app on whichever is older.")
            connection?.cancel()
        } catch {
            phase = .offline("Couldn't understand \(mac.name).")
            connection?.cancel()
        }
    }

    private func send(_ message: ClientMessage) {
        guard let connection, let data = try? FrameCodec.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func failWaiting() {
        let pending = waiting
        waiting = [:]
        for continuation in pending.values { continuation.resume(throwing: PhoneError.notConnected) }
    }

    private func watchSilence() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if phase == .connected, Date().timeIntervalSince(lastHeard) > Self.silenceSeconds {
                phase = .offline("\(mac.name) stopped answering.")
                connection?.cancel()
            }
        }
    }
}
