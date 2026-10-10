import Foundation

/// Which Apple container releases Gannin sandboxes sessions with
/// (andrew-waters/gannin#8, R20). Below `minimum` it won't; up to `tested`
/// it runs and offers Update; newer than `tested` it runs, noted as untested
/// but never blocked, so an update to container can't lock anyone out.
/// Moving to a new release: run the spike's checks on it (the plan's Spike
/// results), then bump `tested`, `installer` and `installerSHA256` together.
nonisolated enum SandboxSupport {
    static let minimum = ContainerVersion(1, 4, 1)
    static let tested = ContainerVersion(1, 5, 0)
    /// Apple's signed installer for `tested`, from its GitHub release.
    static let installer = URL(string: "https://github.com/apple/container/releases/download/1.5.0/container-1.5.0-installer-signed.pkg")!
    static let installerSHA256 = "a24808cb202318fa1c3bbee0c6c6887fe1225fe899d7b687a0ddd939bd6573f8"

    /// What Gannin relies on beyond the version: each is a flag a
    /// subcommand's help has to list. A release that renames one is caught
    /// here, by name, whatever its version says.
    nonisolated struct Feature: Sendable, Hashable {
        /// The subcommand whose help is read (`run`, `system start`).
        let command: String
        let flag: String
        /// What it's for, to say when it's missing.
        let use: String
    }

    static let features: [Feature] = [
        Feature(command: "run", flag: "--mount", use: "mounting folders read-only"),
        Feature(command: "run", flag: "--tmpfs", use: "hiding other sessions' folders"),
        Feature(command: "run", flag: "--label", use: "labelling Gannin's containers"),
        Feature(command: "run", flag: "--cpus", use: "CPU caps"),
        Feature(command: "run", flag: "--memory", use: "memory caps"),
        Feature(command: "list", flag: "--format", use: "reading containers as JSON"),
        Feature(command: "system start", flag: "--disable-kernel-install", use: "starting the service without a prompt"),
    ]

    /// How a box's container stands against the policy.
    nonisolated enum Verdict: Sendable, Equatable {
        /// No container on the box.
        case missing
        /// Older than `minimum`, or without a feature Gannin uses.
        case unsupported(ContainerVersion?, missing: [Feature])
        /// Works, but older than `tested`: Update is offered.
        case older(ContainerVersion)
        case tested
        /// Newer than `tested`: runs, said to be untested.
        case newer(ContainerVersion)

        /// Whether sessions can be sandboxed with it.
        var canSandbox: Bool {
            switch self {
            case .missing, .unsupported: false
            case .older, .tested, .newer: true
            }
        }

        /// Whether Install or Update to `tested` is worth offering.
        var offersInstall: Bool {
            switch self {
            case .missing, .unsupported, .older: true
            case .tested, .newer: false
            }
        }
    }

    static func verdict(version: ContainerVersion?, installed: Bool, missing: [Feature]) -> Verdict {
        guard installed else { return .missing }
        guard let version, version >= minimum, missing.isEmpty else { return .unsupported(version, missing: missing) }
        if version < tested { return .older(version) }
        return version == tested ? .tested : .newer(version)
    }
}

/// A container release's version, `1.5.0`.
nonisolated struct ContainerVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The first `x.y` or `x.y.z` in the text, so both `1.5.0` and
    /// `container CLI version 1.5.0 (build: release, commit: d265d66)` read.
    init?(_ text: String) {
        guard let match = text.firstMatch(of: #/(\d+)\.(\d+)(?:\.(\d+))?/#),
              let major = Int(match.1), let minor = Int(match.2) else { return nil }
        self.init(major, minor, match.3.flatMap { Int($0) } ?? 0)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (a: ContainerVersion, b: ContainerVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}
