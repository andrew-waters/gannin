import Foundation
import Testing
@testable import Gannin

/// Finding Apple container on a box and judging it against the support
/// policy (andrew-waters/gannin#8, R1, R2, R17, R20).
struct SandboxRuntimeTests {
    @Test func versionsReadFromTheCLIAndCompare() {
        #expect(ContainerVersion("container CLI version 1.5.0 (build: release, commit: d265d66)") == ContainerVersion(1, 5, 0))
        #expect(ContainerVersion("1.4") == ContainerVersion(1, 4, 0))
        #expect(ContainerVersion("no version here") == nil)
        #expect(ContainerVersion(1, 4, 1) < ContainerVersion(1, 5, 0))
        #expect(ContainerVersion(1, 10, 0) > ContainerVersion(1, 9, 9))
        #expect(ContainerVersion(2, 0, 0).description == "2.0.0")
    }

    @Test func thePolicyIsConsistent() {
        #expect(SandboxSupport.minimum <= SandboxSupport.tested)
        // Bumping `tested` means bumping the installer with it.
        #expect(SandboxSupport.installer.absoluteString.contains("/\(SandboxSupport.tested)/"))
        #expect(SandboxSupport.installer.lastPathComponent.contains("\(SandboxSupport.tested)"))
        #expect(SandboxSupport.installerSHA256.count == 64)
        let isHex = SandboxSupport.installerSHA256.allSatisfy { $0.isHexDigit }
        #expect(isHex)
    }

    @Test func verdictsFollowThePolicy() {
        let flag = SandboxSupport.features[0]
        #expect(SandboxSupport.verdict(version: nil, installed: false, missing: []) == .missing)
        #expect(SandboxSupport.verdict(version: ContainerVersion(1, 3, 1), installed: true, missing: []) == .unsupported(ContainerVersion(1, 3, 1), missing: []))
        #expect(SandboxSupport.verdict(version: nil, installed: true, missing: []) == .unsupported(nil, missing: []))
        #expect(SandboxSupport.verdict(version: SandboxSupport.minimum, installed: true, missing: [flag]) == .unsupported(SandboxSupport.minimum, missing: [flag]))
        #expect(SandboxSupport.verdict(version: SandboxSupport.minimum, installed: true, missing: []) == .older(SandboxSupport.minimum))
        #expect(SandboxSupport.verdict(version: SandboxSupport.tested, installed: true, missing: []) == .tested)
        #expect(SandboxSupport.verdict(version: ContainerVersion(9, 0, 0), installed: true, missing: []) == .newer(ContainerVersion(9, 0, 0)))
        // Newer than tested is never blocked.
        #expect(SandboxSupport.Verdict.newer(ContainerVersion(9, 0, 0)).canSandbox)
        #expect(!SandboxSupport.Verdict.newer(ContainerVersion(9, 0, 0)).offersInstall)
        #expect(SandboxSupport.Verdict.older(SandboxSupport.minimum).canSandbox)
        #expect(SandboxSupport.Verdict.older(SandboxSupport.minimum).offersInstall)
    }

    @Test func probeOutputReadsIntoAHost() {
        let output = """
            arch=arm64
            macos=27.0
            binary=/usr/local/bin/container
            version=container CLI version 1.4.1 (build: release, commit: 9a8917c)
            status={"client":{"version":"1.4.1"},"status":"running"}
            kernel=yes
            lacks=run --tmpfs
            noise without an equals sign
            """
        let host = SandboxHost(probe: output)
        #expect(host.isSupportedMac)
        #expect(host.isInstalled)
        #expect(host.version == ContainerVersion(1, 4, 1))
        #expect(host.isRunning)
        #expect(host.hasKernel)
        #expect(host.missing.map(\.flag) == ["--tmpfs"])
        #expect(!host.verdict.canSandbox)
        #expect(host.problem?.contains("hiding other sessions' folders") == true)
    }

    @Test func aStoppedServiceAndNoContainerRead() {
        let stopped = SandboxHost(probe: "arch=arm64\nmacos=26.1\nbinary=/opt/homebrew/bin/container\nversion=1.5.0\nstatus={\"status\":\"unregistered\"}\nkernel=no")
        #expect(stopped.status == "unregistered")
        #expect(!stopped.isRunning)
        #expect(!stopped.hasKernel)
        #expect(stopped.verdict == .tested)
        #expect(stopped.problem == nil)

        let none = SandboxHost(probe: "arch=arm64\nmacos=26.0\nbinary=")
        #expect(none.verdict == .missing)
        #expect(none.problem == "Apple container isn't installed.")
    }

    @Test func unsupportedMacsSayWhy() {
        let intel = SandboxHost(probe: "arch=x86_64\nmacos=26.0\nbinary=/usr/local/bin/container\nversion=1.5.0")
        #expect(!intel.isSupportedMac)
        #expect(intel.problem?.contains("Apple Silicon") == true)

        let old = SandboxHost(probe: "arch=arm64\nmacos=15.6\nbinary=")
        #expect(!old.isSupportedMac)
        #expect(old.problem?.contains("macOS 26 or later") == true)

        let tooOld = SandboxHost(probe: "arch=arm64\nmacos=26.0\nbinary=/usr/local/bin/container\nversion=1.3.1")
        #expect(tooOld.problem?.contains("older than \(SandboxSupport.minimum)") == true)
    }

    @Test func versionNotesForOlderAndNewer() {
        #expect(SandboxHost(probe: "binary=/c\nversion=\(SandboxSupport.minimum)").versionNote?.contains("tested with") == true)
        #expect(SandboxHost(probe: "binary=/c\nversion=\(SandboxSupport.tested)").versionNote == nil)
        #expect(SandboxHost(probe: "binary=/c\nversion=99.0.0").versionNote?.contains("newer") == true)
    }

    @Test func statusReadsOnlyFromJSON() {
        #expect(SandboxHost.status(fromJSON: #"{"status":"running"}"#) == "running")
        #expect(SandboxHost.status(fromJSON: "apiserver is not running") == "")
        #expect(SandboxHost.status(fromJSON: "") == "")
    }

    /// The probe runs anywhere, container or not, and always reports the
    /// Mac it ran on.
    @Test func probeScriptRunsHere() {
        let result = Shell.run(SandboxRuntime.probeScript, .local)
        #expect(result.ok)
        let host = SandboxHost(probe: result.output)
        #expect(!host.architecture.isEmpty)
        #expect(host.macOSMajor != nil)
        if host.isInstalled {
            #expect(host.version != nil)
        }
    }

    @Test func probeScriptChecksEveryFeature() {
        let script = SandboxRuntime.probeScript
        for feature in SandboxSupport.features {
            #expect(script.contains("lacks=\(feature.command) \(feature.flag)"))
        }
    }

    @Test func installersCheckTheHashBeforeInstalling() {
        let remote = SandboxRuntime.remoteInstallScript
        let check = remote.range(of: SandboxSupport.installerSHA256)
        let install = remote.range(of: "sudo /usr/sbin/installer")
        #expect(check != nil && install != nil)
        if let check, let install { #expect(check.upperBound < install.lowerBound) }
        #expect(remote.contains("set -e"))
    }

    @Test func adminScriptEscapesForAppleScript() {
        let script = SandboxRuntime.adminScript(#"[ "$(shasum 'a b')" = x ] && installer -pkg '/tmp/a\b'"#)
        #expect(script.hasPrefix("do shell script \""))
        #expect(script.hasSuffix("\" with administrator privileges"))
        #expect(script.contains(#"\"$(shasum 'a b')\""#))
        #expect(script.contains(#"/tmp/a\\b"#))
    }

    @Test func installTerminalsAskForATerminal() {
        #expect(SandboxRuntime.withTerminal("ssh studio") == "ssh -t studio")
        #expect(SandboxRuntime.withTerminal("ssh -t studio") == "ssh -t studio")
        #expect(SandboxRuntime.withTerminal("/usr/bin/ssh -p 2222 studio") == "/usr/bin/ssh -t -p 2222 studio")
        #expect(SandboxRuntime.withTerminal("mosh studio") == "mosh studio")
        let remote = SandboxRuntime.remoteBash(SandboxRuntime.remoteInstallScript)
        let encoded = remote.components(separatedBy: "printf %s ")[1].components(separatedBy: " |")[0]
        let decoded = Shell.run("printf %s \(encoded) | base64 -d", .local)
        #expect(decoded.output.hasPrefix(String(SandboxRuntime.remoteInstallScript.prefix(20))))
    }

    @Test func remoteBoxesNeedSSH() {
        #expect(SandboxBox.local.runner != nil)
        #expect(SandboxBox.remote(connect: "ssh -t studio").runner != nil)
        #expect(SandboxBox.remote(connect: "mosh studio").runner == nil)
        #expect(SandboxRuntime.name(.remote(connect: "ssh -t studio")) == "studio")
    }
}
