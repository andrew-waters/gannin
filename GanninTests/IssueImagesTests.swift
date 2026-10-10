import AppKit
import Foundation
import Testing
@testable import Gannin

/// Images attached to new issues: committed to the harness and linked from
/// the description.
struct IssueImagesTests {
    private let link = URL(string: "https://github.com/acme/harness/blob/abc123/attachments/issues/acme/app/2026-10-10-3f9a2c1d/shot.png?raw=true")!

    @Test func folderIsByRepoDayAndID() {
        let id = UUID(uuidString: "3F9A2C1D-0000-0000-0000-000000000000")!
        let day = Date(timeIntervalSince1970: 1_791_633_600) // 2026-10-10 noon UTC
        #expect(IssueImages.folder(repo: "acme/app", id: id, date: day) == "attachments/issues/acme/app/2026-10-10-3f9a2c1d")
    }

    @Test func linkIsTheFileAtTheCommitRaw() {
        let url = IssueImages.url(harness: "acme/harness", commit: "abc123", path: "attachments/issues/acme/app/2026-10-10-3f9a2c1d/shot.png")
        #expect(url == link)
    }

    @Test func placeholdersAreAddedAndRemoved() {
        let one = IssueImages.appendingPlaceholder(for: "shot.png", to: "It breaks.\n\n")
        #expect(one == "It breaks.\n\n![shot](attachment:shot.png)")
        #expect(IssueImages.appendingPlaceholder(for: "shot.png", to: "") == "![shot](attachment:shot.png)")
        #expect(IssueImages.removingPlaceholder(for: "shot.png", from: one) == "It breaks.")
    }

    @Test func placeholdersPointAtTheirImages() {
        let text = "Before:\n\n![shot](attachment:shot.png)\n\nAfter."
        #expect(IssueImages.body(text, links: [("shot.png", link)]) == "Before:\n\n![shot](\(link.absoluteString))\n\nAfter.")
    }

    @Test func imagesWithNoPlaceholderGoAtTheEnd() {
        #expect(IssueImages.body("Rewritten by Claude.\n", links: [("shot.png", link)]) == "Rewritten by Claude.\n\n![shot](\(link.absoluteString))")
        #expect(IssueImages.body("", links: [("shot.png", link)]) == "![shot](\(link.absoluteString))")
    }

    @Test func placeholdersForImagesNoLongerAttachedAreTakenOut() {
        let text = "Broken.\n\n![gone](attachment:gone.png)\n\n![shot](attachment:shot.png)"
        #expect(IssueImages.body(text, links: [("shot.png", link)]) == "Broken.\n\n![shot](\(link.absoluteString))")
        #expect(IssueImages.body("Plain text, no images.", links: []) == "Plain text, no images.")
    }

    @Test func similarNamesDontMatchEachOther() {
        let other = URL(string: "https://example.com/shot-2.png")!
        let text = "![shot](attachment:shot.png) ![shot-2](attachment:shot-2.png)"
        #expect(IssueImages.body(text, links: [("shot.png", link), ("shot-2.png", other)])
                == "![shot](\(link.absoluteString)) ![shot-2](\(other.absoluteString))")
    }

    @Test func createTitleNamesTheImages() {
        #expect(IssueImages.createTitle("Create Issue", count: 0) == "Create Issue")
        #expect(IssueImages.createTitle("Create Issue", count: 1) == "Create Issue and Commit 1 Image")
        #expect(IssueImages.createTitle("Add Draft", count: 3) == "Add Draft and Commit 3 Images")
    }

    @Test func webImagesAreKeptAndOthersBecomePNG() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let tiff = try #require(rep.representation(using: .tiff, properties: [:]))
        let kept = try IssueImages.prepared(name: "shot.png", data: png)
        #expect(kept.name == "shot.png" && kept.data == png)
        let converted = try IssueImages.prepared(name: "scan.tiff", data: tiff)
        #expect(converted.name == "scan.png")
        #expect(converted.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(throws: IssueImageError.self) { try IssueImages.prepared(name: "notes.txt", data: Data("hi".utf8)) }
        #expect(throws: IssueImageError.self) { try IssueImages.prepared(name: "broken.heic", data: Data("hi".utf8)) }
    }

    @Test func namesAreMadeUniqueInASet() {
        let set = IssueImageSet()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        #expect(set.add(name: "Screen Shot.png", data: png)?.name == "Screen-Shot.png")
        #expect(set.add(name: "Screen Shot.png", data: png)?.name == "Screen-Shot-2.png")
        #expect(set.add(name: "notes.txt", data: Data()) == nil)
        #expect(set.error != nil)
        #expect(set.count == 2)
    }
}
