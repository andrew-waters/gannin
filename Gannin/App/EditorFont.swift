import AppKit

/// The font for diffs (Repositories, sessions and PR reviews) and the
/// Claude Code terminal, picked from the system Font panel (Settings >
/// General); a monospaced system font at 12pt until changed.
@Observable
final class EditorFontStore: NSObject {
    static let shared = EditorFontStore()

    private static let key = "editorFont"
    static let defaultFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private(set) var font: NSFont

    /// Set by `GanninApp` to push a new font onto every terminal already running.
    var onChange: ((NSFont) -> Void)?

    private override init() {
        font = Self.load()
    }

    private static func load() -> NSFont {
        guard let data = UserDefaults.standard.data(forKey: key),
              let font = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data)
        else { return defaultFont }
        return font
    }

    var isCustom: Bool { UserDefaults.standard.data(forKey: Self.key) != nil }

    var fontDescription: String {
        "\(font.displayName ?? font.fontName), \(Int(font.pointSize))pt"
    }

    /// Opens the system Font panel, set to report changes here.
    func showPanel() {
        NSFontManager.shared.target = self
        NSFontManager.shared.action = #selector(changeFont(_:))
        NSFontManager.shared.setSelectedFont(font, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    /// The Font panel's action, sent here as its target.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        set(sender.convert(font))
    }

    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        set(Self.defaultFont)
    }

    private func set(_ newFont: NSFont) {
        font = newFont
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: newFont, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        onChange?(newFont)
    }
}
