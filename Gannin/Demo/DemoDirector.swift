import AppKit
import SwiftUI

/// Poses the demo build for `scripts/capture-screenshots.sh`. Launched with
/// `--capture <folder>`, it lists the shots in `<folder>/shots`, then waits
/// for the script to write `<shot> <dark|light>` to `<folder>/request`,
/// poses it, and once it has settled writes `<shot> <appearance> <window>`
/// to `<folder>/posed` for `screencapture -l`. Only this app's appearance
/// changes, never the Mac's.
@MainActor
final class DemoDirector {
    private static var current: DemoDirector?

    private let folder: URL
    private var handled = ""
    private var posedShot: DemoShot?
    private var window: NSWindow?

    /// How long a pose is given to draw (avatars load, charts animate).
    private static let settle: Duration = .seconds(2.5)
    private static let appearanceSettle: Duration = .seconds(1)

    private init(folder: URL) {
        self.folder = folder
    }

    /// Starts when the app was launched to capture.
    static func startIfCapturing() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--capture"), arguments.indices.contains(index + 1) else { return }
        let director = DemoDirector(folder: URL(filePath: arguments[index + 1], directoryHint: .isDirectory))
        current = director
        // In front, so its windows draw as the key window does.
        NSApp.activate()
        director.write("shots", DemoShot.allCases.map(\.rawValue).joined(separator: "\n"))
        Task { await director.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
            guard let request = try? String(contentsOf: folder.appending(path: "request"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !request.isEmpty, request != handled else { continue }
            handled = request
            let parts = request.split(separator: " ").map(String.init)
            guard parts.count == 2, let shot = DemoShot(rawValue: parts[0]), let appearance = AppAppearance(rawValue: parts[1]) else {
                write("posed", "\(request) error unknown shot or appearance")
                continue
            }
            write("posed", "\(request) \(await pose(shot, appearance))")
        }
    }

    /// Poses the shot (unless it's the one showing) in the appearance, and
    /// returns its window's number once it has settled in front, or why not.
    private func pose(_ shot: DemoShot, _ appearance: AppAppearance) async -> String {
        appearance.apply()
        if posedShot != shot {
            switch shot.pose {
            case .main(let sidebar, let drawer):
                window = await openMain(sidebar, drawer: drawer)
            case .session(let id):
                window = await openSession(id)
            }
            posedShot = shot
            guard let window else { posedShot = nil; return "error no window for the shot" }
            window.setContentSize(shot.size)
            window.center()
            try? await Task.sleep(for: Self.settle)
        } else {
            try? await Task.sleep(for: Self.appearanceSettle)
        }
        guard let window else { return "error no window for the shot" }
        guard await bringToFront(window) else {
            return "error another app kept the focus; leave the Mac alone while it captures"
        }
        return String(window.windowNumber)
    }

    /// Makes the window key in the active app, so it draws as the one in
    /// use (coloured window buttons, the selection's accent) rather than
    /// greyed: anything taking the focus between shots (a click, a
    /// notification) leaves it inactive. macOS may refuse an app that
    /// asks without a click, so it's asked again for a few seconds.
    private func bringToFront(_ window: NSWindow) async -> Bool {
        for _ in 0..<30 {
            if NSApp.isActive && window.isKeyWindow {
                // Long enough to redraw as active.
                try? await Task.sleep(for: .milliseconds(400))
                return NSApp.isActive && window.isKeyWindow
            }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    /// A new main window on the pose, so nothing from the last shot (a
    /// drawer, a scroll) is left over; the old one closes.
    private func openMain(_ sidebar: SidebarItem, drawer: DetailSelection?) async -> NSWindow? {
        guard let openWindow = GanninAppDelegate.openWindow else { return nil }
        let old = mainWindows
        let request = NavigationRequest(org: DemoFixture.org, sidebar: sidebar, path: [], workspace: nil,
                                        palette: drawer.map { PaletteDestination(org: DemoFixture.org, target: .page($0)) })
        WindowRequest.open(request, placement: .window, openWindow: openWindow)
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if let new = mainWindows.first(where: { window in !old.contains { $0 === window } }) {
                old.forEach { $0.close() }
                return new
            }
        }
        return nil
    }

    /// The main windows showing (the `main` window group's).
    private var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    /// The Claude Code window on the session's tab.
    private func openSession(_ id: UUID) async -> NSWindow? {
        guard let openWindow = GanninAppDelegate.openWindow, let sessions = GanninAppDelegate.sessions else { return nil }
        sessions.reveal(id)
        openWindow(id: SessionStore.windowID)
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix(SessionStore.windowID) == true }) {
                return window
            }
        }
        return nil
    }

    private func write(_ name: String, _ text: String) {
        try? (text + "\n").write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
    }
}
