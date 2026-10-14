import AppKit

/// Avatars for the fixture's invented people and org: their initials on a
/// colour of their own, drawn at launch into the demo's folder, so nothing
/// is loaded from GitHub and no real face appears.
enum DemoAvatars {
    private static let folder = AppPaths.support.appending(path: "Avatars", directoryHint: .isDirectory)

    private static let colours: [NSColor] = [
        .systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal,
        .systemGreen, .systemIndigo, .systemRed, .systemBrown, .systemMint,
    ]

    /// The file for `login`, drawn on first use.
    static func url(_ login: String, name: String?) -> URL {
        let url = folder.appending(path: "\(login).png")
        if !FileManager.default.fileExists(atPath: url.path) { draw(login: login, name: name, to: url) }
        return url
    }

    private static func initials(_ login: String, name: String?) -> String {
        let words = (name ?? login).split(whereSeparator: { $0 == " " || $0 == "-" })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    private static func draw(login: String, name: String?, to url: URL) {
        let side = 160
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The same colour for the same login on every launch.
        let index = login.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % colours.count
        colours[index].usingColorSpace(.deviceRGB)?.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        let text = initials(login, name: name) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
