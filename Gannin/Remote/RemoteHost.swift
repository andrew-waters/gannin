import Foundation
import GanninRemote
import Network
import Observation

/// Listens for paired phones on the local network and keeps each told what its sessions
/// are doing (andrew-waters/gannin plans/2026-10-13-ios-remote-control.md). Off until
/// Settings › Remote turns it on, and unable to start without a `RemoteTransportSecurity`
/// to secure the connection with.
@Observable
final class RemoteHost {
    enum Status: Equatable {
        case off
        case starting
        case listening
        case failed(String)
    }

    static let enabledKey = "remote.enabled"
    static let nameKey = "remote.macName"
    static let maxConnections = 8
    static let heartbeatSeconds = 15
    /// Sessions change many times a second while claude works; the phone is told at most this often.
    static let refreshMilliseconds = 300

    private(set) var status: Status = .off
    private(set) var connectionCount = 0
    /// The pairing secret on offer, until it's used, expires or is cancelled.
    private(set) var pairing: PairingWindow?
    let phones: PairedPhones

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let security: any RemoteTransportSecurity
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [RemoteConnection] = []
    /// Links accepted but not yet ready: held here, since nothing else keeps one alive until it is.
    @ObservationIgnored private var pending: [NetworkLink] = []
    /// The one pairing exchange in progress, if any. Others from unpaired phones are turned away.
    @ObservationIgnored private var pairingConnection: PairingConnection?
    @ObservationIgnored private let confirmPairing: @MainActor (String) async -> Bool
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?

    init(store: SessionStore, phones: PairedPhones = PairedPhones(), security: any RemoteTransportSecurity = UnconfiguredTransportSecurity(), defaults: UserDefaults = .standard, confirmPairing: @escaping @MainActor (String) async -> Bool = PairingConfirmation.ask) {
        self.store = store
        self.confirmPairing = confirmPairing
        self.phones = phones
        self.security = security
        self.defaults = defaults
        phones.onRevoke = { [weak self] phone in
            self?.connections.filter { $0.phone.id == phone.id }.forEach { $0.close() }
        }
    }

    var isAvailable: Bool { security.isAvailable }

    static var defaultName: String { Host.current().localizedName ?? "Mac" }

    var macName: String {
        let name = defaults.string(forKey: Self.nameKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? Self.defaultName : name
    }

    /// Starts or stops to match the setting. Called at launch and when it changes.
    func apply() {
        stop()
        if defaults.bool(forKey: Self.enabledKey) { start() }
    }

    func start() {
        guard listener == nil else { return }
        guard security.isAvailable else {
            status = .failed(RemoteHostError.securityNotConfigured.localizedDescription)
            return
        }
        do {
            let listener = try NWListener(using: try security.listenerParameters())
            listener.service = NWListener.Service(name: macName, type: RemoteProtocol.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            status = .starting
            listener.start(queue: .main)
            refresh()
            startHeartbeat()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Closes every connection and stops advertising.
    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        listener?.cancel()
        listener = nil
        for connection in connections { connection.close() }
        connections = []
        for link in pending { link.close() }
        pending = []
        pairingConnection?.close()
        pairingConnection = nil
        connectionCount = 0
        pairing = nil
        status = .off
    }

    /// The invite for a phone to scan or type, nil while there's no key to put in it.
    func beginPairing() -> PairingInvite? {
        guard let fingerprint = security.macFingerprint else { return nil }
        let window = PairingWindow()
        pairing = window
        return PairingInvite(secret: window.secret, macFingerprint: fingerprint, macName: macName)
    }

    func cancelPairing() {
        pairing = nil
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let link = NetworkLink(connection)
        pending.append(link)
        link.onReady = { [weak self, weak link] in
            guard let self, let link else { return }
            self.pending.removeAll { $0 === link }
            // The handshake has proved the phone holds the key it presented. A paired key gets its
            // sessions; any other key may only pair, and only while a pairing code is on offer.
            guard let fingerprint = self.security.peerFingerprint(of: connection) else {
                link.close()
                return
            }
            guard let phone = self.phones.phone(for: fingerprint) else {
                self.acceptPairing(over: link, phoneFingerprint: fingerprint)
                return
            }
            let remote = RemoteConnection(
                phone: phone,
                fingerprint: fingerprint,
                link: link,
                handler: RemoteIntentHandler(control: self.store),
                phones: self.phones,
                macName: self.macName,
                snapshot: { [store = self.store] in RemoteSessionMirror(store: store).sessions() }
            )
            link.onData = { [weak remote] data in remote?.receive(data) }
            link.onClose = { [weak remote] in remote?.linkClosed() }
            remote.onClose = { [weak self] closed in
                self?.connections.removeAll { $0 === closed }
                self?.connectionCount = self?.connections.count ?? 0
            }
            self.connections.append(remote)
            self.connectionCount = self.connections.count
            remote.start()
            link.startReceiving()
        }
        link.onClose = { [weak self, weak link] in
            guard let self, let link else { return }
            self.pending.removeAll { $0 === link }
        }
        link.start()
    }

    /// Holds a connection from an unpaired key to the pairing exchange.
    private func acceptPairing(over link: NetworkLink, phoneFingerprint: Data) {
        guard pairing != nil, pairingConnection == nil, let macFingerprint = security.macFingerprint else {
            link.close()
            return
        }
        let exchange = PairingConnection(
            link: link,
            macFingerprint: macFingerprint,
            phoneFingerprint: phoneFingerprint,
            isOpen: { [weak self] in self?.pairing?.isOpen() ?? false },
            consume: { [weak self] in self?.pairing?.consume() },
            confirm: confirmPairing,
            onPaired: { [weak self] name in
                self?.phones.add(name: name, fingerprint: phoneFingerprint)
                self?.pairing = nil
            }
        )
        link.onData = { [weak exchange] data in exchange?.receive(data) }
        link.onClose = { [weak exchange] in exchange?.linkClosed() }
        exchange.onClose = { [weak self] in self?.pairingConnection = nil }
        pairingConnection = exchange
        exchange.start()
        link.startReceiving()
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready: status = .listening
        case .failed(let error):
            let message = error.localizedDescription
            stop()
            status = .failed(message)
        default: break
        }
    }

    // MARK: Keeping phones up to date

    /// Reads the sessions, noting what that read touched, so the next change in any of it
    /// schedules another. Connected phones are sent what differs.
    private func refresh() {
        guard listener != nil else { return }
        let sessions = withObservationTracking {
            RemoteSessionMirror(store: store).sessions()
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        for connection in connections { connection.push(sessions) }
        // The terminal screen isn't observable. Keep reading until a pending prompt's
        // choices have drawn, even if the transcript and session state stay unchanged.
        if sessions.contains(where: { session in
            if case .permission(_, _, _, _, let choices) = session.prompt { return choices.isEmpty }
            return false
        }) {
            scheduleRefresh()
        }
        if let window = pairing, window.expiresAt < .now { pairing = nil }
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [self] in
            try? await Task.sleep(for: .milliseconds(Self.refreshMilliseconds))
            guard !Task.isCancelled else { return }
            refreshTask = nil
            refresh()
        }
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatSeconds))
                for connection in connections { connection.heartbeat() }
            }
        }
    }
}
