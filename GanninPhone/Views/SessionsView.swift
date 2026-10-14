import GanninRemote
import SwiftUI

extension RemoteSessionState {
    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .idle: "Your turn"
        case .exited: "Claude exited"
        case .stopped: "Stopped"
        }
    }

    var color: Color {
        switch self {
        case .needsYou: .orange
        case .working, .starting: .blue
        case .idle: .green
        case .exited, .stopped: .gray
        }
    }
}

/// One Mac's sessions, the ones waiting on you first.
struct SessionsView: View {
    @Environment(\.phoneServices) private var services
    @Environment(MacBrowser.self) private var browser
    let mac: PairedMac
    var onClientCreated: (RemoteClient) -> Void
    @State private var client: RemoteClient?

    var body: some View {
        Group {
            if let client {
                SessionList(client: client)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(mac.name)
        .onAppear {
            browser.start()
            if client == nil {
                client = RemoteClient(mac: mac, security: services.security, endpoint: { [browser] in browser.endpoint(for: mac.name) })
                if let client { onClientCreated(client) }
            }
            client?.start()
        }
    }
}

private struct SessionList: View {
    let client: RemoteClient

    var body: some View {
        List {
            switch client.phase {
            case .connecting:
                Section { ProgressView("Connecting…") }
            case .offline(let reason):
                Section { Label(reason, systemImage: "wifi.slash").foregroundStyle(.secondary) }
            default:
                EmptyView()
            }
            if client.phase == .connected, client.state.sessions.isEmpty {
                ContentUnavailableView("No sessions", systemImage: "terminal", description: Text("Sessions on this Mac appear here."))
            }
            let ordered = client.state.ordered
            ForEach(ordered) { session in
                NavigationLink {
                    SessionView(client: client, sessionID: session.id)
                } label: {
                    SessionRow(session: session)
                }
            }
        }
        // A new "Needs you" is a tap on the wrist while the app is open. There's no push: iOS
        // suspends the app soon after it leaves the screen.
        .onChange(of: client.state.needsYou.count) { old, new in
            if new > old { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
    }
}

struct SessionRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(session.state.color).frame(width: 10, height: 10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.headline).lineLimit(2)
                Text("\(session.kind) · \(session.reference)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if session.mode == .unattended {
                Image(systemName: "bolt.fill").foregroundStyle(.secondary).accessibilityLabel("Unattended")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(session.state.label)
    }
}
