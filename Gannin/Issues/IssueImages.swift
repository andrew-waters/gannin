import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Images attached to an issue as it's created (andrew-waters/gannin#122,
// plans/2026-10-10-attach-images-to-issues.md). GitHub's API has no upload
// for issue attachments (the web editor's go through the browser's session),
// so they're committed to the project's harness and the issue's description
// links to them there, pinned to the commit. Only people who can read the
// harness see them.

/// An image attached to a new issue, held until it's created.
struct IssueImage: Identifiable {
    let id: UUID
    /// Safe for a path, and unique among the issue's images.
    let name: String
    let data: Data
    let image: NSImage?
}

enum IssueImageError: LocalizedError {
    case notImage(String)
    case unreadable(String)
    case tooLarge(String)

    var errorDescription: String? {
        switch self {
        case .notImage(let name): "\(name) isn't an image."
        case .unreadable(let name): "Gannin couldn't read \(name) as a picture."
        case .tooLarge(let name): "\(name) is over \(ByteCountFormatter.string(fromByteCount: Int64(IssueImages.maxBytes), countStyle: .file)), even as a JPEG: more than Gannin commits through GitHub's API. Attach a smaller one."
        }
    }
}

enum IssueImages {
    /// What browsers show inline, kept as they are; any other image is
    /// kept as a PNG.
    static let webTypes: [UTType] = [.png, .jpeg, .gif, .webP]
    /// The most an image can be, as a harness commit takes it.
    static let maxBytes = HarnessChange.maxDataBytes
    /// Where in the harness they go.
    static let root = "attachments/issues"
    /// A placeholder's link, `attachment:<name>`, until the image is committed.
    static let scheme = "attachment"

    // MARK: Preparing

    /// An image as it's committed: a web type as it is, anything else as a
    /// PNG, and one over the limit as a JPEG when that fits (not a GIF,
    /// which would lose its frames).
    static func prepared(name: String, data: Data) throws -> (name: String, data: Data) {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        let type = UTType(filenameExtension: ext)
        guard type?.conforms(to: .image) ?? true else { throw IssueImageError.notImage(name) }
        var name = name
        var data = data
        if !(type.map { kind in webTypes.contains { kind.conforms(to: $0) } } ?? false) {
            guard let png = encoded(data, as: .png) else { throw IssueImageError.unreadable(name) }
            name = "\(stem).png"
            data = png
        }
        if data.count > maxBytes {
            guard type?.conforms(to: .gif) != true, let jpeg = encoded(data, as: .jpeg), jpeg.count <= maxBytes else {
                throw IssueImageError.tooLarge(name)
            }
            name = "\(stem).jpg"
            data = jpeg
        }
        return (name, data)
    }

    private static func encoded(_ data: Data, as type: NSBitmapImageRep.FileType) -> Data? {
        let rep = NSBitmapImageRep(data: data)
            ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        return rep?.representation(using: type, properties: type == .jpeg ? [.compressionFactor: 0.85] : [:])
    }

    // MARK: Where they go

    /// The folder one issue's images go in:
    /// `attachments/issues/<owner>/<name>/<2026-10-10>-<8 hex>`.
    static func folder(repo: String, id: UUID, date: Date) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        let short = id.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        return "\(root)/\(repo)/\(day)-\(short)"
    }

    /// The link an issue shows it by: the file at that commit, raw, which
    /// GitHub serves to anyone who can read the repo, private ones included.
    static func url(harness: String, commit: String, path: String) -> URL? {
        URL(string: "https://github.com/\(harness)/blob/\(commit)/\(path)?raw=true")
    }

    /// Who will see them, for the sheet to say before they're committed.
    static func audience(harness: String, repo: String) -> String {
        let place = harness == repo
            ? "They're committed to \(repo) under \(root)/ and show in the issue to anyone who can see it."
            : "They're committed to the harness, \(harness), under \(root)/, and show in the issue only to people who can read \(harness)."
        return place + " Git keeps them in its history, so leave out customer details and anything else sensitive."
    }

    /// A Create button's title, naming the images it commits.
    static func createTitle(_ title: String, count: Int) -> String {
        count == 0 ? title : "\(title) and Commit \(count == 1 ? "1 Image" : "\(count) Images")"
    }

    // MARK: The description

    /// `![shot](attachment:shot.png)`, where the image goes until it's committed.
    static func placeholder(for name: String) -> String {
        "![\((name as NSString).deletingPathExtension)](\(scheme):\(name))"
    }

    /// The text with an image's placeholder added at the end.
    static func appendingPlaceholder(for name: String, to text: String) -> String {
        let trimmed = text.replacing(/\s+$/, with: "")
        return trimmed.isEmpty ? placeholder(for: name) : "\(trimmed)\n\n\(placeholder(for: name))"
    }

    /// The text without an image's placeholder, and the blank line before it.
    static func removingPlaceholder(for name: String, from text: String) -> String {
        let tag = placeholder(for: name)
        return text.replacingOccurrences(of: "\n\n\(tag)", with: "").replacingOccurrences(of: tag, with: "")
    }

    /// The description as it's sent: each placeholder pointed at its image,
    /// images with none left (removed, or dropped by Claude's draft) added at
    /// the end, and placeholders for images no longer attached taken out, so
    /// nothing links nowhere.
    static func body(_ text: String, links: [(name: String, url: URL)]) -> String {
        var body = text
        var missing: [String] = []
        for link in links {
            let target = "(\(scheme):\(link.name))"
            if body.contains(target) {
                body = body.replacingOccurrences(of: target, with: "(\(link.url.absoluteString))")
            } else {
                missing.append("![\((link.name as NSString).deletingPathExtension)](\(link.url.absoluteString))")
            }
        }
        body = body.replacing(/\n*!\[[^\]\n]*\]\(attachment:[^)\s]*\)/, with: "")
        guard !missing.isEmpty else { return body }
        let trimmed = body.replacing(/\s+$/, with: "")
        return (trimmed.isEmpty ? "" : "\(trimmed)\n\n") + missing.joined(separator: "\n\n")
    }
}

// MARK: - One issue's images

/// The images attached to one new issue, and those already committed, so
/// trying again after GitHub refuses the issue links them rather than
/// committing them twice.
@Observable
final class IssueImageSet {
    private(set) var images: [IssueImage] = []
    var error: String?
    /// Links to those committed, by image.
    private var committed: [UUID: URL] = [:]
    /// Names the folder they go in, from when they were first attached.
    private let folderID = UUID()
    private let started = Date.now

    var isEmpty: Bool { images.isEmpty }
    var count: Int { images.count }

    /// Adds an image, under a name unique among them; nil, with `error`
    /// set, when it can't be. `id` keeps one already held elsewhere (a
    /// quick change's screenshot) the same image.
    @discardableResult
    func add(name: String, data: Data, id: UUID = UUID()) -> IssueImage? {
        do {
            let prepared = try IssueImages.prepared(name: name, data: data)
            let unique = SessionStore.attachmentNames(images.map(\.name) + [prepared.name]).last ?? prepared.name
            let image = IssueImage(id: id, name: unique, data: prepared.data, image: NSImage(data: prepared.data))
            images.append(image)
            error = nil
            return image
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func remove(_ image: IssueImage) {
        images.removeAll { $0.id == image.id }
    }

    /// Keeps only those with these IDs.
    func keep(_ ids: Set<UUID>) {
        images.removeAll { !ids.contains($0.id) }
    }

    func add(file url: URL) -> IssueImage? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
            error = IssueImageError.notImage(url.lastPathComponent).localizedDescription
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            error = IssueImageError.unreadable(url.lastPathComponent).localizedDescription
            return nil
        }
        return add(name: url.lastPathComponent, data: data)
    }

    /// A pasted or dropped picture with no file, a PNG or TIFF.
    func add(picture data: Data) -> IssueImage? {
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        return add(name: "image-\(images.count + 1).\(isPNG ? "png" : "tiff")", data: data)
    }

    /// What's on the pasteboard: image files copied in Finder, else a
    /// picture. From ⌘V, only when that's all there is, so text still
    /// pastes. Nil when it took nothing.
    func paste(fromKeyboard: Bool) -> [IssueImage]? {
        let board = NSPasteboard.general
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let pictures = files.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !files.isEmpty, !fromKeyboard || pictures.count == files.count {
            return files.compactMap { add(file: $0) }
        }
        if files.isEmpty, !fromKeyboard || board.string(forType: .string) == nil,
           let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
            return [add(picture: data)].compactMap { $0 }
        }
        if !fromKeyboard { error = "There's no picture on the clipboard." }
        return nil
    }

    func pick() -> [IssueImage] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Images to show in the issue"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { add(file: $0) }
    }

    /// Commits those not committed yet to the harness, in one commit, and
    /// returns every image's link. `repo` is the issue's, naming the folder.
    /// Callers have had it confirmed.
    func commit(org: String, repo: String, setup: HarnessConfig, harness: HarnessStore) async throws -> [(name: String, url: URL)] {
        let pending = images.filter { committed[$0.id] == nil }
        if !pending.isEmpty {
            let folder = IssueImages.folder(repo: repo, id: folderID, date: started)
            let files = Dictionary(pending.map { ("\(folder)/\($0.name)", $0.data) }) { _, last in last }
            let message = "Gannin: \(pending.count == 1 ? "an image" : "\(pending.count) images") for a new issue in \(repo)"
            let commit = try await harness.commit(org: org, setup: setup, refreshing: false) { _ in
                HarnessChange(message: message, files: [:], data: files)
            }
            guard let commit else { return [] }
            for image in pending {
                committed[image.id] = IssueImages.url(harness: setup.repo, commit: commit, path: "\(folder)/\(image.name)")
            }
        }
        return images.compactMap { image in committed[image.id].map { (image.name, $0) } }
    }
}

// MARK: - In a sheet

/// Images for a new issue: a drop zone (files, files promised by the
/// screenshot thumbnail and other apps, or a picture), Paste (and ⌘V in its
/// window while the clipboard holds only pictures), Add Images, thumbnails
/// to remove, and who'll see them once committed.
struct IssueImagesSection: View {
    let images: IssueImageSet
    /// The harness they're committed to; nil when the project has none.
    let harness: HarnessConfig?
    /// The issue's repo, to say who'll see them.
    let repo: String
    var added: (IssueImage) -> Void = { _ in }
    var removed: (IssueImage) -> Void = { _ in }

    @State private var targeted = false

    var body: some View {
        Section {
            if let harness {
                if !images.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(images.images) { thumbnail($0) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Text(targeted ? "Drop to attach" : "Drop images here")
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background {
                        // AppKit's, as the form's own views take a drag before
                        // SwiftUI's drop destinations see it.
                        ScreenshotDropTarget(targeted: $targeted, files: { urls in
                            urls.compactMap { images.add(file: $0) }.forEach(added)
                        }, image: { data in
                            if let image = images.add(picture: data) { added(image) }
                        }, paste: {
                            guard let taken = images.paste(fromKeyboard: true) else { return false }
                            taken.forEach(added)
                            return true
                        })
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .allowsHitTesting(false)
                    }
                    .accessibilityLabel("Drop images here")
                HStack {
                    Text(images.isEmpty ? "Or paste them (⌘V) or add them." : "\(images.count) attached")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Paste") { images.paste(fromKeyboard: false)?.forEach(added) }
                        .help("Attach the picture or image files on the clipboard")
                    Button("Add Images") { images.pick().forEach(added) }
                }
                if !images.isEmpty {
                    Label {
                        Text(IssueImages.audience(harness: harness.repo, repo: repo))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                    }
                    .font(.caption)
                }
            } else {
                Text("Attaching images needs a project with a harness to commit them to (the org's Settings, under Projects): GitHub's API has no way to upload them to the issue itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Images")
        } footer: {
            if let error = images.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if harness != nil {
                Text("PNG, JPEG, GIF or WebP, up to \(ByteCountFormatter.string(fromByteCount: Int64(IssueImages.maxBytes), countStyle: .file)) each; other pictures are kept as PNG. They show inline in the issue, and nothing's committed until it's created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func thumbnail(_ image: IssueImage) -> some View {
        VStack(spacing: 4) {
            Group {
                if let picture = image.image {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 80)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                Button {
                    images.remove(image)
                    removed(image)
                } label: {
                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .padding(3)
                .help("Remove \(image.name)")
                .accessibilityLabel("Remove \(image.name)")
            }
            Text(image.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 120)
        }
    }
}
