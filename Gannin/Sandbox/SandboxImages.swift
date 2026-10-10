import CryptoKit
import Foundation

/// The images sandboxes run (andrew-waters/gannin#8, R1, R9, R13): Gannin's
/// base image, built from the Containerfile here, and a repo's own, built
/// from `.gannin/sandbox/<repo>.Containerfile` in the harness on top of it.
/// Each is tagged by a hash of what it's built from, so it's built once and
/// again only when that changes. Everything Gannin makes is labelled
/// `dev.andon.gannin=1`, and cleanup touches nothing else.
nonisolated enum SandboxImages {
    static let label = "dev.andon.gannin=1"
    static let labelKey = "dev.andon.gannin"

    /// Claude Code, git, gh, Node, Python and build tools on Debian. git
    /// trusts the mounted folders (they belong to the Mac user, not root),
    /// signs in to GitHub through gh with `GH_TOKEN`, and signs commits with
    /// an SSH key, set when a sandbox starts.
    static let baseContainerfile = """
        # Gannin's sandbox base image: what a Claude Code session needs to work on
        # most repos in Linux. A repo extends it with a Containerfile of its own in
        # the harness, starting FROM gannin-base.
        FROM docker.io/library/node:22-bookworm-slim
        LABEL dev.andon.gannin=1
        ENV DEBIAN_FRONTEND=noninteractive
        RUN apt-get update \\
            && apt-get install -y --no-install-recommends \\
                ca-certificates curl git openssh-client gnupg build-essential pkg-config \\
                python3 python3-pip python3-venv jq ripgrep unzip zip less procps \\
            && install -d -m 0755 /etc/apt/keyrings \\
            && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \\
            && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \\
            && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \\
            && apt-get update \\
            && apt-get install -y --no-install-recommends gh \\
            && rm -rf /var/lib/apt/lists/*
        RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force
        # Files belong to the Mac user, not root; GH_TOKEN signs git in through gh;
        # commits are signed with the sandbox's SSH key, set when it starts.
        RUN git config --system safe.directory '*' \\
            && git config --system credential.https://github.com.helper '' \\
            && git config --system --add credential.https://github.com.helper '!gh auth git-credential' \\
            && git config --system gpg.format ssh
        ENV DISABLE_AUTOUPDATER=1
        CMD ["sleep", "infinity"]

        """

    /// `gannin-base:<hash>`, from the Containerfile above.
    static var baseTag: String { "gannin-base:" + hash(baseContainerfile) }

    /// What a repo's Containerfile is called in the harness.
    static func repoContainerfile(_ repo: String) -> String {
        ".gannin/sandbox/\(repoName(repo)).Containerfile"
    }

    /// The image name for a repo, before its hash: `gannin-<name>`.
    static func repoImage(_ repo: String) -> String {
        "gannin-" + repoName(repo).lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? String($0) : "-" }.joined()
    }

    private static func repoName(_ repo: String) -> String {
        String(repo.split(separator: "/").last ?? Substring(repo))
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    // MARK: Building

    /// Builds the base image on the box when it isn't there, and points
    /// `gannin-base:latest` at it for repos' Containerfiles.
    static func ensureBase(_ host: SandboxHost, on box: SandboxBox) async throws {
        try await run(baseScript(container: SandboxRuntime.quoted(host.binary)), on: box, failing: "Gannin's base image didn't build.")
    }

    /// `container`: the binary as a shell word.
    static func baseScript(container c: String) -> String {
        let tag = baseTag
        return """
            set -e
            if ! \(c) image inspect \(tag) >/dev/null 2>&1; then
              d=$(mktemp -d "${TMPDIR:-/tmp}/gannin-base.XXXXXX")
              trap 'rm -rf "$d"' EXIT
              \(Shell.piped(baseContainerfile)) > "$d/Containerfile"
              \(c) build --progress plain -f "$d/Containerfile" -t \(tag) --label \(label) "$d"
            fi
            \(c) image tag \(tag) gannin-base:latest
            """
    }

    /// The image a session for `repo` runs: its own, built from its
    /// Containerfile in the harness checkout (`harness`, a shell word, on the
    /// box) and tagged by a hash of that and the base, else the base.
    static func image(for repo: String, harness: String, host: SandboxHost, on box: SandboxBox) async throws -> String {
        try await ensureBase(host, on: box)
        let result = try await run(repoScript(repo: repo, harness: harness, container: SandboxRuntime.quoted(host.binary)), on: box, failing: "\(repoName(repo))'s sandbox image didn't build.")
        return image(fromOutput: result.output) ?? baseTag
    }

    static func repoScript(repo: String, harness: String, container c: String) -> String {
        return """
            set -e
            f=\(harness)/\(SandboxRuntime.quoted(repoContainerfile(repo)))
            if [ ! -f "$f" ]; then echo "image=\(baseTag)"; exit 0; fi
            h=$({ cat "$f"; echo \(baseTag); } | /usr/bin/shasum -a 256 | cut -c1-12)
            tag=\(repoImage(repo)):$h
            if ! \(c) image inspect "$tag" >/dev/null 2>&1; then
              \(c) build --progress plain -f "$f" -t "$tag" --label \(label) "$(dirname "$f")"
            fi
            echo "image=$tag"
            """
    }

    /// The `image=` line the repo script ends with, past the build's output.
    static func image(fromOutput output: String) -> String? {
        output.split(separator: "\n").last { $0.hasPrefix("image=") }.map { String($0.dropFirst("image=".count)) }
    }

    // MARK: Cleanup

    /// Removes every container and image Gannin labelled on the box (R13).
    /// Nothing without the label is touched.
    static func removeAll(_ host: SandboxHost, on box: SandboxBox) async throws {
        let c = SandboxRuntime.quoted(host.binary)
        let containers = try await run("\(c) list --all --format json", on: box, failing: "Couldn't list containers.")
        let ids = labelledContainers(fromJSON: containers.output)
        if !ids.isEmpty {
            try await run("\(c) delete --force \(ids.map(SandboxRuntime.quoted).joined(separator: " "))", on: box, failing: "Couldn't remove Gannin's sandboxes.")
        }
        let images = try await run("\(c) image list --format json", on: box, failing: "Couldn't list images.")
        let names = labelledImages(fromJSON: images.output)
        if !names.isEmpty {
            try await run("\(c) image delete \(names.map(SandboxRuntime.quoted).joined(separator: " "))", on: box, failing: "Couldn't remove Gannin's images.")
        }
    }

    /// Containers labelled as Gannin's, by ID, from `container list --format json`.
    static func labelledContainers(fromJSON text: String) -> [String] {
        guard let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let configuration = item["configuration"] as? [String: Any],
                  let labels = configuration["labels"] as? [String: String],
                  labels[labelKey] == "1" else { return nil }
            return configuration["id"] as? String
        }
    }

    /// Images labelled as Gannin's, by name, from `container image list
    /// --format json`: the label is in each variant's config.
    static func labelledImages(fromJSON text: String) -> [String] {
        guard let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let configuration = item["configuration"] as? [String: Any],
                  let name = configuration["name"] as? String,
                  let variants = item["variants"] as? [[String: Any]] else { return nil }
            let labelled = variants.contains { variant in
                let config = (variant["config"] as? [String: Any])?["config"] as? [String: Any]
                return (config?["Labels"] as? [String: String])?[labelKey] == "1"
            }
            return labelled ? name : nil
        }
    }

    @discardableResult
    private static func run(_ script: String, on box: SandboxBox, failing message: String) async throws -> Shell.Result {
        guard let runner = box.runner else {
            throw SandboxRuntime.Failure(message: "The Connect with command isn't ssh, so Gannin can't build images on \(SandboxRuntime.name(box)).", output: "")
        }
        let result = await Task.detached { Shell.run(script, runner) }.value
        guard result.ok else { throw SandboxRuntime.Failure(message: message, output: result.failure) }
        return result
    }
}
