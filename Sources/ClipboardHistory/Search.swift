import Foundation

/// Ranks: prefix match > word-start match > substring, then by recency (input order). Pure for tests.
enum Search {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func score(_ text: String, query q: String) -> Int {
        guard let r = text.range(of: q) else { return 0 }
        if r.lowerBound == text.startIndex { return 3 }
        let before = text[text.index(before: r.lowerBound)]
        return before.isWhitespace || before.isPunctuation ? 2 : 1
    }

    static func filter<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return items }
        var scored: [(offset: Int, score: Int, item: T)] = []
        for (offset, item) in items.enumerated() {
            let s = score(text(item), query: q)
            if s > 0 { scored.append((offset, s, item)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
        return scored.map(\.item)
    }
}
