import Foundation
import Testing
@testable import Gannin

/// The images sandboxes run and cleaning up after them (andrew-waters/gannin#8,
/// R1, R9, R13).
struct SandboxImagesTests {
    @Test func theBaseIsTaggedByWhatItsBuiltFrom() {
        let tag = SandboxImages.baseTag
        #expect(tag.hasPrefix("gannin-base:"))
        #expect(tag.count == "gannin-base:".count + 12)
        #expect(SandboxImages.hash("a") == SandboxImages.hash("a"))
        #expect(SandboxImages.hash("a") != SandboxImages.hash("b"))
        #expect(SandboxImages.baseContainerfile.contains("LABEL dev.andon.gannin=1"))
        #expect(SandboxImages.baseContainerfile.contains("@anthropic-ai/claude-code"))
    }

    @Test func reposNameTheirFileAndImage() {
        #expect(SandboxImages.repoContainerfile("andrew-waters/gannin") == ".gannin/sandbox/gannin.Containerfile")
        #expect(SandboxImages.repoImage("andrew-waters/My_App") == "gannin-my-app")
        #expect(SandboxImages.repoImage("acme/api.v2") == "gannin-api.v2")
    }

    @Test func theRepoScriptFallsBackToTheBase() {
        let script = SandboxImages.repoScript(repo: "acme/api", harness: #""$HOME"/'Code/acme-harness'"#, binary: "/usr/local/bin/container")
        #expect(script.contains(#"f="$HOME"/'Code/acme-harness'/'.gannin/sandbox/api.Containerfile'"#))
        #expect(script.contains("echo \"image=\(SandboxImages.baseTag)\""))
        // The repo's hash covers the base, so a new base rebuilds it.
        #expect(script.contains("echo \(SandboxImages.baseTag); } | /usr/bin/shasum"))
        #expect(script.contains("--label dev.andon.gannin=1"))
    }

    @Test func theImageIsTheLastLine() {
        let output = "#1 building\nimage=not-this\n#9 done\nimage=gannin-api:0123456789ab\n"
        #expect(SandboxImages.image(fromOutput: output) == "gannin-api:0123456789ab")
        #expect(SandboxImages.image(fromOutput: "no image here") == nil)
    }

    @Test func theBaseScriptCarriesItsContainerfile() {
        let script = SandboxImages.baseScript(binary: "/usr/local/bin/container")
        #expect(script.contains(Data(SandboxImages.baseContainerfile.utf8).base64EncodedString()))
        #expect(script.contains("image tag \(SandboxImages.baseTag) gannin-base:latest"))
    }

    @Test func onlyGanninsContainersAreFound() {
        let json = """
            [{"configuration":{"id":"traefik","labels":{}}},
             {"configuration":{"id":"alpine-sandbox","labels":{"com.orchard.sandbox":"true"}}},
             {"configuration":{"id":"gannin-3f9a","labels":{"dev.andon.gannin":"1","com.orchard.sandbox":"true"}}},
             {"configuration":{"id":"buildkit","labels":{"com.apple.container.plugin":"builder"}}}]
            """
        #expect(SandboxImages.labelledContainers(fromJSON: json) == ["gannin-3f9a"])
        #expect(SandboxImages.labelledContainers(fromJSON: "not json").isEmpty)
    }

    @Test func onlyGanninsImagesAreFound() {
        let json = """
            [{"configuration":{"name":"docker.io/library/alpine:latest"},
              "variants":[{"config":{"config":{"Labels":{"maintainer":"someone"}}}}]},
             {"configuration":{"name":"gannin-base:0123456789ab"},
              "variants":[{"config":{"config":{"Labels":{"dev.andon.gannin":"1"}}}}]},
             {"configuration":{"name":"postgres:16-alpine"},"variants":[{"config":{"config":{}}}]}]
            """
        #expect(SandboxImages.labelledImages(fromJSON: json) == ["gannin-base:0123456789ab"])
    }
}
