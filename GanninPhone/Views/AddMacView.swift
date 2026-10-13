import AVFoundation
import GanninRemote
import Network
import SwiftUI

/// Pairs with a Mac: scan the code it shows, or pick it from the Macs on this network and type the code.
struct AddMacView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.phoneServices) private var services
    @Environment(PairedMacs.self) private var macs
    @Environment(MacBrowser.self) private var browser
    @State private var scanning = false
    @State private var typed = ""
    @State private var chosen: String?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Scan the code on your Mac", systemImage: "qrcode.viewfinder") { scanning = true }
                } footer: {
                    Text("On your Mac, open Settings › Remote and choose Pair a Phone.")
                }
                Section("Or type the code") {
                    Picker("Mac", selection: $chosen) {
                        Text("Choose a Mac").tag(String?.none)
                        ForEach(browser.endpoints.keys.sorted(), id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    TextField("Code", text: $typed)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button("Pair") { pairTyped() }
                        .disabled(working || chosen == nil || PairingSecret(code: typed) == nil)
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
                if working {
                    Section { ProgressView("Pairing…") }
                }
            }
            .navigationTitle("Add a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() } }
            .fullScreenCover(isPresented: $scanning) {
                NavigationStack {
                    QRScannerView { text in
                        scanning = false
                        pairScanned(text)
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan the code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Cancel") { scanning = false } }
                }
            }
        }
        .onAppear { browser.start() }
    }

    private func pairScanned(_ text: String) {
        guard let url = URL(string: text), let invite = PairingInvite(url: url) else {
            failure = "That isn't a Gannin pairing code."
            return
        }
        guard let endpoint = browser.endpoint(for: invite.macName) else {
            failure = "Can't find \(invite.macName) on this network. Is this phone on the same Wi-Fi?"
            return
        }
        pair(secret: invite.secret, fingerprint: invite.macFingerprint, endpoint: endpoint)
    }

    private func pairTyped() {
        guard let secret = PairingSecret(code: typed), let name = chosen, let endpoint = browser.endpoint(for: name) else { return }
        pair(secret: secret, fingerprint: nil, endpoint: endpoint)
    }

    private func pair(secret: PairingSecret, fingerprint: Data?, endpoint: NWEndpoint) {
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                let mac = try await services.pairing.pair(secret: secret, expectedMacFingerprint: fingerprint, via: endpoint)
                macs.add(mac)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

/// Reads one QR code from the camera and reports its text.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

/// AVCaptureSession isn't Sendable, and starting it blocks, so it's started off the main
/// thread from inside this box, the only thing that touches it there.
private nonisolated final class CaptureBox: @unchecked Sendable {
    let session = AVCaptureSession()

    func start() { session.startRunning() }
    func stop() { session.stopRunning() }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let box = CaptureBox()
    private var preview: AVCaptureVideoPreviewLayer?
    private var reported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let session = box.session
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let box = box
        Task.detached { box.start() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let box = box
        Task.detached { box.stop() }
    }

    /// AVFoundation calls this on the main queue given to `setMetadataObjectsDelegate`, which is the main
    /// actor's executor, but the protocol can't say so. `assumeIsolated` doesn't switch to the main actor:
    /// it asserts we're already on it, and traps if the queue ever stops being `.main`. Kept synchronous so
    /// `reported` is checked and set before the next frame's call.
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // The metadata objects aren't Sendable, so only the string leaves this method.
        guard let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        MainActor.assumeIsolated {
            guard !reported else { return }
            reported = true
            onCode?(text)
        }
    }
}
