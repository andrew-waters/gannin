import AppKit
import Foundation
import Testing
@testable import Gannin

/// Design and Refine screenshots: small enough for a harness commit, and
/// named so they don't clash.
@MainActor
struct RefineScreenshotsTests {
    /// Noise, which doesn't compress, at a retina screen's size.
    private func noise(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 42
        for index in bytes.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes[index] = index % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: seed >> 24)
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func largeScreenshotComesOutUnderTheBudget() throws {
        let image = try noise(width: 3840, height: 2400)
        let encoded = try #require(RefineScreenshots.encode(image))
        #expect(encoded.data.count <= RefineScreenshots.budget)
        #expect(encoded.ext == "jpg")
        let rep = try #require(NSBitmapImageRep(data: encoded.data))
        #expect(rep.pixelsWide == RefineScreenshots.maxWidth)
        #expect(rep.pixelsHigh == 1000)
    }

    @Test func smallScreenshotStaysPNG() throws {
        let image = try noise(width: 200, height: 100)
        let encoded = try #require(RefineScreenshots.encode(image))
        #expect(encoded.ext == "png")
    }

    @Test func namesSkipThoseTaken() {
        #expect(RefineScreenshots.nextName(taken: []) == "screenshot-1")
        #expect(RefineScreenshots.nextName(taken: ["screenshot-1.png"]) == "screenshot-2")
        #expect(RefineScreenshots.nextName(taken: ["screenshot-2.jpg"]) == "screenshot-3")
        #expect(RefineScreenshots.nextName(taken: ["screenshot-2.jpg", "screenshot-3.png"]) == "screenshot-4")
    }
}
