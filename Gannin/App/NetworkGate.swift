import Foundation

/// The demo build's seal (`DEMO`): nothing reaches the network or the
/// keychain, and no claude, git, gh or shell starts. Every sender and every
/// process launcher checks it first, so something the demo didn't stop by
/// itself fails loudly instead of reaching GitHub or running as the user.
nonisolated enum NetworkGate {
    static let isSealed: Bool = {
        #if DEMO
        true
        #else
        false
        #endif
    }()

    /// A request (with its URL) or a process (without) the seal refused.
    struct Sealed: LocalizedError {
        let url: URL?
        var errorDescription: String? {
            guard let url else { return Self.process }
            return "The demo build makes no network requests (\(url.host() ?? "no host"))."
        }

        static let process = "The demo build starts no claude, git, gh or shell."
    }

    /// Throws in the demo build.
    static func check(_ url: URL?) throws {
        if isSealed { throw Sealed(url: url) }
    }

    /// Throws in the demo build, before a process starts.
    static func checkProcess() throws {
        if isSealed { throw Sealed(url: nil) }
    }
}
