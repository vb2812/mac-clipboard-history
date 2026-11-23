import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// ⌥⌘V: see SPEC §3 for why.
    static let openPanel = Self("openPanel", default: .init(.v, modifiers: [.option, .command]))
}

/// UserDefaults keys and defaults. Views use @AppStorage with the same keys.
enum Prefs {
    static let historyLimit = "historyLimit"          // Int, default 25
    static let maxItemMB = "maxItemMB"                // Int, default 100
    static let paused = "paused"
    static let clearOnQuit = "clearOnQuit"
    static let excludedApps = "excludedApps"          // [String]
    static let hideFromCapture = "hideFromCapture"    // default true
    static let showAppIcons = "showAppIcons"          // default true
    static let showFooter = "showFooter"              // default true
    static let onboarded = "onboarded"
    static let plainByDefault = "plainByDefault"      // Return pastes plain text, ⇧Return keeps formatting
    static let expireHours = "expireHours"            // Int, 0 = never
    static let clearOnLock = "clearOnLock"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            historyLimit: 25, maxItemMB: 100, paused: false, clearOnQuit: false,
            excludedApps: PrivacyFilter.defaultExcludedApps, hideFromCapture: true,
            showAppIcons: true, showFooter: true, onboarded: false,
            plainByDefault: false, expireHours: 0, clearOnLock: false,
        ])
    }

    static var d: UserDefaults { .standard }
}

/// Our own conflict rules on top of KeyboardShortcuts' system/menu check.
@MainActor
enum ShortcutRules {
    enum Result: Equatable { case ok, warn(String), block(String) }

    /// Shortcuts that every text app relies on; recording these would break basic editing.
    static let reserved: Set<String> = ["⌘V", "⌘C", "⌘X", "⌘Z", "⇧⌘Z", "⌘A", "⌘Q", "⌘W", "⌘S", "⌘Tab", "⌘Space", "⌘,"]
    /// Common in-app shortcuts that would be shadowed while Clipboard History runs.
    static let shadowed: [String: String] = [
        "⇧⌘V": "Paste and Match Style in many apps",
        "⌥⇧⌘V": "Paste and Match Style in Pages, Keynote, Mail and Xcode",
        "⌃⌘V": "Paste Special in some apps",
        "⌥⌘V": "Finder's “Move Item Here” (only when moving copied files)",
        "⌘N": "New Window/Document", "⌘T": "New Tab", "⌘F": "Find", "⌘P": "Print", "⌘O": "Open",
    ]

    static func check(_ shortcut: KeyboardShortcuts.Shortcut) -> Result {
        check(description: shortcut.description, modifiers: shortcut.modifiers)
    }

    static func check(description: String, modifiers: NSEvent.ModifierFlags) -> Result {
        let mods = modifiers.intersection([.command, .option, .control])
        if mods.isEmpty { return .block("Add ⌘, ⌥ or ⌃ so the shortcut doesn't type a character.") }
        if reserved.contains(description) { return .block("\(description) is a basic editing shortcut.") }
        if let what = shadowed[description] { return .warn("\(description) is also \(what).") }
        return .ok
    }
}

/// Text forms of a hex color for "Copy as …" (designer request S-02). Pure for tests.
enum ColorFormat {
    static func rgb(_ hex: String) -> String? {
        guard let (r, g, b) = components(hex) else { return nil }
        return "rgb(\(r), \(g), \(b))"
    }

    static func hsl(_ hex: String) -> String? {
        guard let (r8, g8, b8) = components(hex) else { return nil }
        let r = Double(r8) / 255, g = Double(g8) / 255, b = Double(b8) / 255
        let maxV = max(r, g, b), minV = min(r, g, b), l = (maxV + minV) / 2
        var h = 0.0, s = 0.0
        if maxV != minV {
            let d = maxV - minV
            s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
            switch maxV {
            case r: h = (g - b) / d + (g < b ? 6 : 0)
            case g: h = (b - r) / d + 2
            default: h = (r - g) / d + 4
            }
            h *= 60
        }
        return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }

    private static func components(_ hex: String) -> (Int, Int, Int)? {
        var t = hex.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#") else { return nil }
        t.removeFirst()
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard t.count == 6 || t.count == 8, let v = UInt64(t.prefix(6), radix: 16) else { return nil }
        return (Int(v >> 16 & 0xFF), Int(v >> 8 & 0xFF), Int(v & 0xFF))
    }
}
