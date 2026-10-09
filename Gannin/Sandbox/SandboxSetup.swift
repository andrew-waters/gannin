import Foundation
import Observation

/// Getting a box ready to sandbox sessions (R1, R2, R17), one step at a
/// time with progress, for Settings to show: check the Mac and container,
/// install or update it (this Mac only, after asking), start its service and
/// set a kernel when there's none. Each step that fails keeps what the CLI
/// said, to show in full.
@Observable
final class SandboxSetup {
    enum StepKind: String, CaseIterable {
        case check, install, start, kernel

        var title: String {
            switch self {
            case .check: "Check this Mac"
            case .install: "Install Apple container \(SandboxSupport.tested)"
            case .start: "Start Apple container"
            case .kernel: "Set the Linux kernel"
            }
        }
    }

    enum StepState: Equatable {
        case waiting, running, done, skipped
        case failed(String)
    }

    struct Step: Identifiable, Equatable {
        let kind: StepKind
        var state: StepState = .waiting
        var id: StepKind { kind }
    }

    let box: SandboxBox
    private(set) var host: SandboxHost?
    private(set) var steps: [Step] = []
    /// What the CLI said when the last step failed.
    private(set) var output = ""
    private(set) var isRunning = false

    init(box: SandboxBox) {
        self.box = box
    }

    /// Whether the box can sandbox sessions now: a supported Mac, a version
    /// the policy runs, the service running and a kernel set.
    var isReady: Bool {
        guard let host else { return false }
        return host.problem == nil && host.verdict.canSandbox && host.isRunning && host.hasKernel
    }

    /// Why it can't, in plain words, once checked.
    var problem: String? {
        if let failed = steps.first(where: { if case .failed = $0.state { true } else { false } }), case .failed(let message) = failed.state {
            return message
        }
        guard let host else { return nil }
        if let problem = host.problem { return problem }
        if !host.isRunning { return "Apple container's service isn't running." }
        if !host.hasKernel { return "Apple container has no Linux kernel set." }
        return nil
    }

    /// Install or Update can be offered: on this Mac, which is supported,
    /// with container missing, too old or older than tested. A remote Mac's
    /// is installed in a terminal over `ssh -t` (`SandboxRuntime.remoteInstallScript`).
    var offersInstall: Bool {
        guard let host, host.isSupportedMac else { return false }
        return host.verdict.offersInstall
    }

    /// Reads the box again without changing anything.
    func check() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        steps = [Step(kind: .check)]
        output = ""
        _ = await inspect()
    }

    /// Makes the box ready: checks it, installs (`installing`, this Mac
    /// only, once the user has agreed to the admin prompt and to stopping
    /// what runs there), starts the service when it isn't running and sets
    /// the recommended kernel when none is set. Stops at the first failure.
    func setUp(installing: Bool) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let install = installing && box.isLocal
        steps = StepKind.allCases.filter { $0 != .install || install }.map { Step(kind: $0) }
        output = ""

        guard var host = await inspect() else { return }
        if !host.isSupportedMac {
            fail(.check, host.problem ?? "This Mac can't run Apple container.")
            return
        }
        if install {
            let ok = await perform(.install) { try await SandboxRuntime.install(stopping: host.isInstalled ? host : nil) }
            guard ok, let checked = await reinspect() else { return }
            host = checked
        }
        if !host.verdict.canSandbox {
            fail(.start, host.problem ?? "Apple container can't sandbox sessions here.")
            return
        }
        if host.isRunning {
            set(.start, .skipped)
        } else {
            let found = host
            guard await perform(.start, { try await SandboxRuntime.start(found, on: self.box) }), let checked = await reinspect() else { return }
            host = checked
        }
        if host.hasKernel {
            set(.kernel, .skipped)
        } else {
            let found = host
            guard await perform(.kernel, { try await SandboxRuntime.setKernel(found, on: self.box) }) else { return }
            _ = await reinspect()
        }
    }

    // MARK: Steps

    private func inspect() async -> SandboxHost? {
        set(.check, .running)
        do {
            let host = try await SandboxRuntime.inspect(box)
            self.host = host
            set(.check, .done)
            return host
        } catch {
            fail(.check, error)
            return nil
        }
    }

    /// Reads the box again after a step changed it, without a step of its own.
    private func reinspect() async -> SandboxHost? {
        do {
            let host = try await SandboxRuntime.inspect(box)
            self.host = host
            return host
        } catch {
            fail(.check, error)
            return nil
        }
    }

    private func perform(_ kind: StepKind, _ work: () async throws -> Void) async -> Bool {
        set(kind, .running)
        do {
            try await work()
            set(kind, .done)
            return true
        } catch {
            fail(kind, error)
            return false
        }
    }

    private func fail(_ kind: StepKind, _ error: Error) {
        if let failure = error as? SandboxRuntime.Failure { output = failure.output }
        fail(kind, error.localizedDescription)
    }

    private func fail(_ kind: StepKind, _ message: String) {
        set(kind, .failed(message))
    }

    private func set(_ kind: StepKind, _ state: StepState) {
        if let index = steps.firstIndex(where: { $0.kind == kind }) {
            steps[index].state = state
        } else {
            steps.append(Step(kind: kind, state: state))
        }
    }
}
