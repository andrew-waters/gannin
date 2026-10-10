import AppKit
import SwiftUI
import UserNotifications

/// Asks before quitting while Claude Code sessions run: their terminals are
/// Gannin's children, so quitting ends claude mid-turn, here or (with the
/// ssh connection it runs through) on a server. And opens a session's tab
/// when its notification is clicked.
final class GanninAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set at launch; the delegate is made by SwiftUI before the stores.
    static weak var sessions: SessionStore?
    /// A window's, kept by `capturesOpenWindow()`, for opening the sessions
    /// window from outside any view.
    static var openWindow: OpenWindowAction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        AppAppearance.current.apply()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let id = (info["session"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        let review = info["review"] as? String
        let mine = info["mine"] as? String
        await MainActor.run {
            // A review request, or one of your PRs.
            if review != nil || mine != nil {
                var keys: [String: String] = [:]
                if let review { keys["review"] = review }
                if let mine { keys["mine"] = mine }
                EngineerWatch.shared.handle(action: action == UNNotificationDefaultActionIdentifier ? "review:open" : action, info: keys)
                if action == "review:claude" { NSApp.activate() }
                return
            }
            guard let id, let sessions = Self.sessions else { return }
            // A quick reply: answer without coming to Gannin.
            if action.hasPrefix("keys:") {
                sessions.handleQuickReply(String(action.dropFirst(5)), for: id)
                return
            }
            sessions.reveal(id)
            Self.openWindow?(id: SessionStore.windowID)
            NSApp.activate()
        }
    }

    /// Shown even with Gannin in front: you may be in another window.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let sessions = Self.sessions else { return .terminateNow }
        let running = sessions.running
        guard !running.isEmpty else { return .terminateNow }

        let working = running.filter { [.starting, .working].contains(sessions.state($0.id)) }
        let waiting = running.filter { sessions.state($0.id) == .needsYou }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = running.count == 1
            ? "Quit and end the Claude Code session?"
            : "Quit and end \(running.count) Claude Code sessions?"

        var lines: [String] = []
        for session in running.prefix(8) {
            lines.append("• \(session.shortReference) \(session.issue.title): \(sessions.state(session.id).label)")
        }
        if running.count > 8 { lines.append("• and \(running.count - 8) more") }
        var explanation: [String] = []
        if !working.isEmpty {
            explanation.append(working.count == 1
                ? "One is working now and stops mid-task: whatever it's in the middle of is lost, though finished edits stay in its worktree."
                : "\(working.count) are working now and stop mid-task: whatever they're in the middle of is lost, though finished edits stay in their worktrees.")
        }
        if !waiting.isEmpty {
            explanation.append(waiting.count == 1 ? "One is waiting on you." : "\(waiting.count) are waiting on you.")
        }
        if running.contains(where: \.isRemote) {
            explanation.append("Sessions on a server end too, as their ssh connection closes.")
        }
        if running.contains(where: { $0.isSandboxed && !$0.isRemote }) {
            explanation.append("Their sandboxes stop, keeping their folders, and start again when a session is opened.")
        }
        explanation.append("Conversations are kept: opening a session again resumes it where it was.")
        alert.informativeText = lines.joined(separator: "\n") + "\n\n" + explanation.joined(separator: " ")

        alert.addButton(withTitle: "Cancel")
        let quit = alert.addButton(withTitle: running.count == 1 ? "Quit and End Session" : "Quit and End Sessions")
        quit.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        sessions.stopSandboxesForQuit()
        return .terminateNow
    }
}

extension View {
    /// Keeps this window's `openWindow` for the app delegate.
    func capturesOpenWindow() -> some View { modifier(CapturesOpenWindow()) }
}

private struct CapturesOpenWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { GanninAppDelegate.openWindow = openWindow }
    }
}

/// Window › Next Session Waiting on You (⇧⌘J), from any window.
struct SessionCommands: Commands {
    let sessions: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Next Session Waiting on You") {
                guard let next = sessions.nextWaiting else { return }
                sessions.show(next, with: openWindow)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
        }
    }
}
