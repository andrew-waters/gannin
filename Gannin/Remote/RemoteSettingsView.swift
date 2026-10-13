import AppKit
import CoreImage.CIFilterBuiltins
import GanninRemote
import SwiftUI

/// Settings › Remote: letting iPhones see this Mac's Claude Code sessions and answer them.
struct RemoteSettingsView: View {
    @Environment(RemoteHost.self) private var host
    @AppStorage(RemoteHost.enabledKey) private var enabled = false
    @AppStorage(RemoteHost.nameKey) private var name = ""
    @State private var invite: PairingInvite?
    @State private var revoking: RemotePhone?

    var body: some View {
        Form {
            Section {
                Toggle("Allow iPhones to control sessions", isOn: $enabled)
                    .disabled(!host.isAvailable)
                TextField("Name on the network", text: $name, prompt: Text(RemoteHost.defaultName))
                    .disabled(!host.isAvailable)
                statusRow
            } header: {
                Text("Remote control")
            } footer: {
                Text("A paired iPhone on the same network, or one reaching this Mac over a VPN you run, can see your sessions and answer what Claude asks. Nothing goes through a Gannin server.")
            }
            Section {
                if host.phones.phones.isEmpty {
                    Text("No phones paired.").foregroundStyle(.secondary)
                }
                ForEach(host.phones.phones) { phone in
                    LabeledContent(phone.name) {
                        HStack {
                            Text(lastSeen(phone)).foregroundStyle(.secondary)
                            Button("Revoke", role: .destructive) { revoking = phone }
                        }
                    }
                }
                Button("Pair a Phone…") { invite = host.beginPairing() }
                    .disabled(!enabled || host.status != .listening)
            } header: {
                Text("Paired phones")
            } footer: {
                Text("A paired phone can approve commands that run as you. Revoke one you've lost.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { host.apply() }
        .onChange(of: name) { if enabled { host.apply() } }
        .sheet(item: $invite, onDismiss: { host.cancelPairing() }) { invite in
            PairPhoneSheet(invite: invite, expiresAt: host.pairing?.expiresAt ?? .now)
        }
        .confirmationDialog("Revoke \(revoking?.name ?? "this phone")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), presenting: revoking) { phone in
            Button("Revoke", role: .destructive) { host.phones.revoke(phone) }
        } message: { _ in
            Text("It's disconnected now and can't reach your sessions again unless you pair it again.")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch host.status {
        case .off:
            Text(host.isAvailable ? "Off." : "Not available in this build yet.").font(.caption).foregroundStyle(.secondary)
        case .starting:
            Text("Starting…").font(.caption).foregroundStyle(.secondary)
        case .listening:
            Text("On as \(host.macName). \(host.connectionCount) connected.").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    private func lastSeen(_ phone: RemotePhone) -> String {
        phone.lastSeen.map { "Seen \($0.formatted(.relative(presentation: .named)))" } ?? "Not seen yet"
    }
}

/// The QR code and typed code for the phone, until the pairing window ends.
private struct PairPhoneSheet: View {
    @Environment(\.dismiss) private var dismiss
    let invite: PairingInvite
    let expiresAt: Date

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a Phone").font(.headline)
            Text("In Gannin on your iPhone, choose Add a Mac and scan this code, or type the code below it. It works once, for two minutes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let image = Self.qr(invite.url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .accessibilityLabel("Pairing code for \(invite.macName)")
            }
            Text(invite.secret.code)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(expiresAt.timeIntervalSince(context.date)))
                Text(left > 0 ? "Expires in \(left) seconds" : "Expired. Close this and start again.")
                    .font(.caption)
                    .foregroundStyle(left > 0 ? Color.secondary : Color.red)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360)
    }

    private static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
