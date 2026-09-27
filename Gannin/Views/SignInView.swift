import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SignInView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.openURL) private var openURL

    @State private var phase: Phase = .idle
    @State private var code: DeviceCode?
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var copied = false

    enum Phase {
        case idle, requesting, awaitingUser, finishing
    }

    var body: some View {
        HStack(spacing: 48) {
            Image("logo")
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .accessibilityLabel("Gannin")

            VStack(alignment: .leading, spacing: 16) {
                Text("Gannin")
                    .font(.largeTitle.weight(.semibold))
                Text("See what your teams are working on across your GitHub orgs.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch phase {
                case .idle:
                    Button(action: start) {
                        Label("Sign in with GitHub", systemImage: "arrow.right.circle.fill")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                case .requesting:
                    progress("Contacting GitHub")
                case .awaitingUser:
                    if let code { codePanel(code) }
                case .finishing:
                    progress("Authorised, loading your profile")
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 360, alignment: .leading)
        }
        .padding(48)
        .frame(minWidth: 720, minHeight: 440)
        .onDisappear { task?.cancel() }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func codePanel(_ code: DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter this code on GitHub:")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(code.userCode)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .tracking(3)
                    .textSelection(.enabled)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Button {
                    copy(code.userCode)
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy code")
            }
            HStack {
                Button("Open GitHub") { openURL(code.verificationURI) }
                    .buttonStyle(.borderedProminent)
                Button("Cancel", action: cancel)
            }
            progress("Waiting for you to authorise")
        }
    }

    private func start() {
        errorMessage = nil
        phase = .requesting
        task?.cancel()
        task = Task {
            do {
                let code = try await DeviceFlow.requestCode()
                self.code = code
                phase = .awaitingUser
                copy(code.userCode)
                openURL(code.verificationURI)
                let token = try await DeviceFlow.pollForToken(code)
                phase = .finishing
                try await auth.completeSignIn(token: token)
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            phase = .idle
            code = nil
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        code = nil
    }

    private func copy(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}
