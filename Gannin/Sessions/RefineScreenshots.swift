import AppKit
import SwiftUI
import WebKit

/// Screenshots of a Design and Refine page: the visible part of the page,
/// annotated, saved small enough to commit to the harness (whose commits
/// refuse files over 5 MB) in the session's folder.
enum RefineScreenshots {
    /// The widest a saved screenshot is, in pixels.
    static let maxWidth = 1600
    /// Past this a screenshot is saved as JPEG rather than PNG.
    static let budget = 1_500_000

    /// The visible part of the page, as it's shown.
    static func capture(_ page: WebPage) async throws -> NSImage {
        let size = try await page.callJavaScript("return [window.innerWidth, window.innerHeight]") as? [NSNumber]
        guard let size, size.count == 2, size[0].doubleValue > 0, size[1].doubleValue > 0 else { throw CaptureError.noPage }
        // The region is in the view's coordinates, so its origin is the
        // top of what's in view however far the page is scrolled.
        let rect = CGRect(x: 0, y: 0, width: size[0].doubleValue, height: size[1].doubleValue)
        let data = try await page.exported(as: .image(region: .rect(rect)))
        guard let image = NSImage(data: data) else { throw CaptureError.noPage }
        return image
    }

    enum CaptureError: LocalizedError {
        case noPage

        var errorDescription: String? { "There's no page to take a screenshot of yet." }
    }

    /// The image no wider than `maxWidth`, as PNG, or JPEG when the PNG
    /// would be over `budget`, with its file extension.
    static func encode(_ image: CGImage, maxWidth: Int = maxWidth, budget: Int = budget) -> (data: Data, ext: String)? {
        let scaled = downscaled(image, maxWidth: maxWidth) ?? image
        let rep = NSBitmapImageRep(cgImage: scaled)
        if let png = rep.representation(using: .png, properties: [:]), png.count <= budget {
            return (png, "png")
        }
        for quality in [0.8, 0.6, 0.4] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= budget {
                return (jpeg, "jpg")
            }
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.3]).map { ($0, "jpg") }
    }

    private static func downscaled(_ image: CGImage, maxWidth: Int) -> CGImage? {
        guard image.width > maxWidth else { return nil }
        let height = Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded())
        guard let context = CGContext(data: nil, width: maxWidth, height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: max(height, 1)))
        return context.makeImage()
    }

    /// The session's folder for screenshots with their marks, and for the
    /// pages as they were, kept to change the marks.
    static func folder(for session: CodeSession) -> URL? {
        SessionStore.worktree(for: session)?.appending(path: "screenshots", directoryHint: .isDirectory)
    }

    static func originals(for session: CodeSession) -> URL? {
        SessionStore.worktree(for: session)?.appending(path: "originals", directoryHint: .isDirectory)
    }

    static func url(_ screenshot: RefineInfo.Screenshot, in session: CodeSession) -> URL? {
        folder(for: session)?.appending(path: screenshot.file)
    }

    static func original(_ screenshot: RefineInfo.Screenshot, in session: CodeSession) -> URL? {
        originals(for: session)?.appending(path: "\(screenshot.id.uuidString).png")
    }

    /// The image with its marks drawn on, at its own size.
    static func flatten(_ image: NSImage, marks: [RefineInfo.Mark]) -> CGImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = CGSize(width: source.width, height: source.height)
        let renderer = ImageRenderer(content: RefineMarkedImage(image: image, marks: marks).frame(width: size.width, height: size.height))
        renderer.scale = 1
        return renderer.cgImage
    }

    /// `screenshot-3`: the next number not taken in the session.
    static func nextName(taken: [String]) -> String {
        let used = Set(taken.map { ($0 as NSString).deletingPathExtension })
        var number = taken.count + 1
        while used.contains("screenshot-\(number)") { number += 1 }
        return "screenshot-\(number)"
    }
}

/// A screenshot with its marks drawn over it, scaled to fit.
struct RefineMarkedImage: View {
    let image: NSImage
    let marks: [RefineInfo.Mark]
    var pending: RefineInfo.Mark? = nil

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                Canvas { context, size in
                    for mark in marks + [pending].compactMap({ $0 }) {
                        Self.draw(mark, in: &context, size: size)
                    }
                }
                .allowsHitTesting(false)
            }
    }

    static let color = Color(red: 1, green: 0.18, blue: 0.33)

    static func draw(_ mark: RefineInfo.Mark, in context: inout GraphicsContext, size: CGSize) {
        let line = max(2, size.width * 0.003)
        let from = CGPoint(x: mark.from.x * size.width, y: mark.from.y * size.height)
        let to = CGPoint(x: mark.to.x * size.width, y: mark.to.y * size.height)
        switch mark.kind {
        case .box:
            let rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
            context.stroke(Path(roundedRect: rect, cornerRadius: line * 2), with: .color(color), lineWidth: line)
        case .arrow:
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = line * 6
            for side in [Double.pi * 0.85, -Double.pi * 0.85] {
                path.move(to: to)
                path.addLine(to: CGPoint(x: to.x + head * cos(angle + side), y: to.y + head * sin(angle + side)))
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
        case .text:
            let text = Text(mark.text ?? "")
                .font(.system(size: max(14, size.width * 0.018), weight: .semibold))
                .foregroundStyle(.white)
            let resolved = context.resolve(text)
            let measured = resolved.measure(in: CGSize(width: size.width * 0.6, height: size.height))
            let rect = CGRect(origin: from, size: measured).insetBy(dx: -line * 2, dy: -line)
            context.fill(Path(roundedRect: rect, cornerRadius: line * 2), with: .color(color))
            context.draw(resolved, in: CGRect(origin: from, size: measured))
        }
    }
}

extension SessionStore {
    /// Saves a screenshot with its marks: a new one, or one taken before
    /// with its marks changed. A new one is attached to `finding`, or to a
    /// new finding noted with `note`. Returns the screenshot saved.
    @discardableResult
    func saveScreenshot(_ image: NSImage, marks: [RefineInfo.Mark], replacing existing: RefineInfo.Screenshot?,
                        url: String, pageTitle: String?, attachTo finding: UUID?, note: String, in id: UUID) throws -> RefineInfo.Screenshot {
        guard let session = sessions[id], let info = session.refine,
              let folder = RefineScreenshots.folder(for: session), let originals = RefineScreenshots.originals(for: session) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard let flat = RefineScreenshots.flatten(image, marks: marks),
              let encoded = RefineScreenshots.encode(flat) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let name = existing.map { ($0.file as NSString).deletingPathExtension }
            ?? RefineScreenshots.nextName(taken: info.screenshots.map(\.file))
        var screenshot = existing ?? RefineInfo.Screenshot(file: "", url: url, at: .now, pageTitle: pageTitle)
        if let existing, existing.file != "\(name).\(encoded.ext)" {
            try? FileManager.default.removeItem(at: folder.appending(path: existing.file))
        }
        screenshot.file = "\(name).\(encoded.ext)"
        screenshot.marks = marks
        try encoded.data.write(to: folder.appending(path: screenshot.file), options: .atomic)
        if existing == nil, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: originals.appending(path: "\(screenshot.id.uuidString).png"), options: .atomic)
        }
        let saved = screenshot
        if existing != nil {
            update(id) { session in
                guard let index = session.refine?.screenshots.firstIndex(where: { $0.id == saved.id }) else { return }
                session.refine?.screenshots[index] = saved
            }
            return saved
        }
        var attached = finding
        if attached == nil {
            attached = addFinding(note, url: url, pageTitle: pageTitle, to: id)?.id
        }
        update(id) { session in
            session.refine?.screenshots.append(saved)
            if let attached, let index = session.refine?.findings.firstIndex(where: { $0.id == attached }) {
                session.refine?.findings[index].screenshots.append(saved.id)
            }
        }
        return saved
    }

    /// Takes a screenshot off its finding, and deletes it with its files.
    func removeScreenshot(_ screenshot: RefineInfo.Screenshot, from id: UUID) {
        guard let session = sessions[id] else { return }
        if let file = RefineScreenshots.url(screenshot, in: session) { try? FileManager.default.removeItem(at: file) }
        if let original = RefineScreenshots.original(screenshot, in: session) { try? FileManager.default.removeItem(at: original) }
        update(id) { session in
            session.refine?.screenshots.removeAll { $0.id == screenshot.id }
            for index in session.refine?.findings.indices ?? 0..<0 {
                session.refine?.findings[index].screenshots.removeAll { $0 == screenshot.id }
            }
        }
    }
}

/// What the annotation sheet is working on: a new screenshot of the page,
/// or one taken before, to change its marks.
struct RefineAnnotating: Identifiable {
    let id = UUID()
    let image: NSImage
    let url: String
    let pageTitle: String?
    var existing: RefineInfo.Screenshot? = nil
}

/// Draws boxes, arrows and text on a screenshot, then attaches it to a
/// finding: a new one, or one already noted.
struct RefineAnnotateSheet: View {
    @Environment(SessionStore.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    let session: CodeSession
    let annotating: RefineAnnotating
    @State private var marks: [RefineInfo.Mark] = []
    @State private var tool: RefineInfo.Mark.Kind = .box
    @State private var pending: RefineInfo.Mark?
    @State private var label = ""
    /// The finding it goes with; nil for a new one, noted with `note`.
    @State private var finding: UUID?
    @State private var note = ""
    @State private var error: String?

    private var findings: [RefineInfo.Finding] { session.refine?.findings ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(annotating.existing == nil ? "Screenshot" : "Change Marks")
                    .font(.title2.weight(.semibold))
                Spacer()
                Picker("Draw", selection: $tool) {
                    ForEach(RefineInfo.Mark.Kind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if tool == .text {
                    TextField("Text to place", text: $label)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                Button("Undo") { _ = marks.popLast() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(marks.isEmpty)
                Button("Clear") { marks = [] }
                    .disabled(marks.isEmpty)
            }
            canvas
            Text(tool == .text ? "Type the text, then click where it goes." : "Drag on the screenshot to draw a \(tool.rawValue.lowercased()).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if annotating.existing == nil {
                Form {
                    Picker("Attach to", selection: $finding) {
                        Text("A new finding").tag(UUID?.none)
                        ForEach(findings.reversed()) { finding in
                            Text(finding.note).lineLimit(1).tag(UUID?.some(finding.id))
                        }
                    }
                    if finding == nil {
                        TextField("Finding", text: $note, prompt: Text("What the room spotted here"))
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: finding == nil ? 110 : 70)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(annotating.existing == nil ? "Attach" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(annotating.existing == nil && finding == nil && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 820, idealWidth: 1100, minHeight: 640, idealHeight: 820)
        .onAppear { marks = annotating.existing?.marks ?? [] }
    }

    private var canvas: some View {
        RefineMarkedImage(image: annotating.image, marks: marks, pending: pending)
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard tool != .text else { return }
                            pending = RefineInfo.Mark(kind: tool, from: point(value.startLocation, geometry.size), to: point(value.location, geometry.size))
                        }.onEnded { value in
                            let from = point(value.startLocation, geometry.size)
                            let to = point(value.location, geometry.size)
                            pending = nil
                            if tool == .text {
                                let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { return }
                                marks.append(RefineInfo.Mark(kind: .text, from: to, to: to, text: text))
                                label = ""
                            } else if hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y) > 4 {
                                marks.append(RefineInfo.Mark(kind: tool, from: from, to: to))
                            }
                        })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .border(Color.separatorLine)
    }

    /// A point in the view as fractions of the image's width and height.
    private func point(_ location: CGPoint, _ size: CGSize) -> CGPoint {
        CGPoint(x: min(max(location.x / max(size.width, 1), 0), 1), y: min(max(location.y / max(size.height, 1), 0), 1))
    }

    private func save() {
        do {
            try sessions.saveScreenshot(annotating.image, marks: marks, replacing: annotating.existing, url: annotating.url,
                                        pageTitle: annotating.pageTitle, attachTo: finding, note: note, in: session.id)
            dismiss()
        } catch {
            self.error = "Couldn't save the screenshot: \(error.localizedDescription)"
        }
    }
}
