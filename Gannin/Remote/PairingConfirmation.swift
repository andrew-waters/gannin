import AppKit

/// The Mac's last word on pairing: the person sees the phone's name and says yes or no.
/// Having the code isn't enough, since the code travels on a QR code anyone could photograph.
enum PairingConfirmation {
    /// Asks whether to pair a phone calling itself `phoneName`. "Don't Pair" is the default button, so
    /// a stray Return doesn't hand a device access to sessions that run commands as the user.
    static func ask(phoneName: String) async -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Pair “\(phoneName)”?"
        alert.informativeText = "It will be able to see your Claude Code sessions and approve commands that run as you. Only pair a phone you just set up yourself."
        alert.addButton(withTitle: "Don't Pair")
        alert.addButton(withTitle: "Pair")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
