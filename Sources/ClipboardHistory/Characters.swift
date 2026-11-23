import Foundation

/// A pickable character entry for the Emoji, Symbols and Kaomoji tabs.
struct Glyph: Hashable, Sendable {
    let value: String
    let name: String   // lowercased, used for search and tooltips
}

enum CharacterSets {
    /// Emoji generated from Unicode properties (no bundled data). Ordered smileys-first.
    static let emoji: [Glyph] = {
        let ranges: [ClosedRange<UInt32>] = [0x1F600...0x1F64F, 0x1F910...0x1F9FF, 0x1F440...0x1F4FF,
                                             0x1F300...0x1F43F, 0x1F500...0x1F5FF, 0x1F680...0x1F6FF,
                                             0x1FA70...0x1FAFF, 0x2600...0x27BF]
        var out: [Glyph] = []
        for range in ranges {
            for v in range {
                guard let s = Unicode.Scalar(v), s.properties.isEmojiPresentation, let name = s.properties.name else { continue }
                out.append(Glyph(value: String(s), name: name.lowercased()))
            }
        }
        // Flags from region codes.
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            let flag = region.identifier.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }
            guard flag.count == 2 else { continue }
            let name = Locale.current.localizedString(forRegionCode: region.identifier) ?? region.identifier
            out.append(Glyph(value: String(String.UnicodeScalarView(flag)), name: "flag \(name.lowercased())"))
        }
        return out
    }()

    static let symbols: [Glyph] = {
        let groups = [
            "arrow": "← → ↑ ↓ ↔ ↕ ↖ ↗ ↘ ↙ ⇐ ⇒ ⇑ ⇓ ⇔ ↩ ↪ ⤴ ⤵ ➔ ➜",
            "math": "± × ÷ ≠ ≈ ≤ ≥ ∞ √ ∑ ∏ ∫ ∂ ∆ ∇ ∈ ∉ ∩ ∪ ⊂ ⊃ ∀ ∃ ¬ ∧ ∨ ° ‰ ¹ ² ³ ½ ¼ ¾ π",
            "currency": "$ € £ ¥ ₹ ₩ ₽ ₺ ₴ ₦ ₫ ₪ ฿ ¢ ₿",
            "punctuation": "… – — · • ‹ › « » “ ” ‘ ’ ¡ ¿ § ¶ † ‡ © ® ™ ℗ № ℃ ℉",
            "keyboard": "⌘ ⌥ ⇧ ⌃ ⎋ ⏎ ⌫ ⌦ ⇥ ⇪ ⏏ ",
            "greek": "α β γ δ ε ζ η θ λ μ ξ σ τ φ χ ψ ω Γ Δ Θ Λ Ξ Σ Φ Ψ Ω",
            "latin": "à á â ä æ ç è é ê ë ì í î ï ñ ò ó ô ö ø œ ß ù ú û ü ÿ",
            "shape": "■ □ ▪ ▫ ▲ △ ▼ ▽ ◆ ◇ ○ ● ◎ ★ ☆ ♠ ♣ ♥ ♦ ✓ ✗ ✔ ✘",
        ]
        return groups.sorted { $0.key < $1.key }.flatMap { group, chars in
            chars.split(separator: " ").map { c in
                let scalarName = c.unicodeScalars.first?.properties.name?.lowercased() ?? ""
                return Glyph(value: String(c), name: "\(group) \(scalarName)")
            }
        }
    }()

    static let kaomoji: [Glyph] = [
        ("happy", "(◕‿◕)"), ("happy", "(＾▽＾)"), ("happy", "ヽ(・∀・)ﾉ"), ("happy", "(•‿•)"), ("happy", "(ᵔᴥᵔ)"),
        ("joy", "(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧"), ("joy", "＼(^o^)／"), ("joy", "(≧▽≦)"), ("joy", "٩(◕‿◕｡)۶"),
        ("love", "(♥‿♥)"), ("love", "(っ˘з(˘⌣˘ )"), ("love", "(´｡• ᵕ •｡`) ♡"), ("love", "♡( ◡‿◡ )"),
        ("sad", "(╥﹏╥)"), ("sad", "(；︵；)"), ("sad", "(ಥ﹏ಥ)"), ("sad", "(´；ω；`)"),
        ("angry", "(╬ Ò﹏Ó)"), ("angry", "(ノಠ益ಠ)ノ彡┻━┻"), ("angry", "(＃`Д´)"), ("angry", "ヽ(`⌒´メ)ノ"),
        ("shrug", "¯\\_(ツ)_/¯"), ("shrug", "┐(￣ヘ￣)┌"), ("shrug", "ʅ(°_°)ʃ"),
        ("surprised", "(⊙_⊙)"), ("surprised", "(°ロ°)"), ("surprised", "Σ(°△°|||)"), ("surprised", "(O_O;)"),
        ("embarrassed", "(⁄ ⁄•⁄ω⁄•⁄ ⁄)"), ("embarrassed", "(〃▽〃)"), ("embarrassed", "(*/ω＼)"),
        ("cat", "(=^･ω･^=)"), ("cat", "ฅ^•ﻌ•^ฅ"), ("bear", "ʕ•ᴥ•ʔ"), ("dog", "U・ᴥ・U"),
        ("wave", "(・ω・)ノ"), ("wave", "ヾ(・ω・*)"), ("table", "┬─┬ノ( º _ ºノ)"), ("lenny", "( ͡° ͜ʖ ͡°)"),
        ("cool", "(⌐■_■)"), ("thinking", "(￢_￢)"), ("sleepy", "(－_－) zzZ"), ("dance", "♪┏(・o･)┛♪"),
        ("hug", "(づ｡◕‿‿◕｡)づ"), ("wink", "(^_~)"), ("flex", "ᕦ(ò_óˇ)ᕤ"), ("run", "ε=ε=┌( >_<)┘"),
    ].map { Glyph(value: $0.1, name: $0.0) }
}

/// Recently used glyphs per tab, most recent first.
enum Recents {
    static let max = 16
    static func get(_ tab: String) -> [String] { UserDefaults.standard.stringArray(forKey: "recents.\(tab)") ?? [] }
    static func add(_ value: String, tab: String) {
        var list = get(tab).filter { $0 != value }
        list.insert(value, at: 0)
        UserDefaults.standard.set(Array(list.prefix(max)), forKey: "recents.\(tab)")
    }
}
