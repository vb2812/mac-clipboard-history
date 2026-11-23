import AppKit
import Combine

enum PanelTab: String, CaseIterable, Identifiable {
    case clipboard = "Clipboard", emoji = "Emoji", symbols = "Symbols", kaomoji = "Kaomoji"
    var id: String { rawValue }
    var columns: Int { self == .kaomoji ? 3 : 8 }
}

enum Banner: Equatable { case paused, noClipboardAccess, recovered }

@MainActor
final class Cursor: ObservableObject {
    @Published var index = 0
}

/// State and keyboard logic for the pop-up. Actions are injected by AppController.
@MainActor
final class PanelModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { recompute() } } }
    @Published var tab: PanelTab = .clipboard { didSet { if tab != oldValue { recompute() } } }
    /// Pinned first, then recent, filtered by the query: the order used for selection and ⌘1–9.
    /// Cached: recomputing it on every render made arrowing through 1,000 items pin the main thread.
    @Published private(set) var clips: [ClipItem] = []
    @Published private(set) var glyphs: [Glyph] = []
    @Published private(set) var recentCount = 0
    /// Selection lives in its own object so moving it doesn't re-render the whole list (only rows observe it).
    let cursor = Cursor()
    var selection: Int {
        get { cursor.index }
        set { if cursor.index != newValue { cursor.index = newValue } }
    }
    @Published var notice: String?
    @Published var banner: Banner?
    @Published var confirmingClear = false
    @Published var commandHeld = false
    @Published var focusRequest = 0
    /// ⌘Y shows a larger preview of the selected item (S-04).
    @Published var previewing = false

    let store: ClipStore
    var onPaste: (ClipItem, _ plain: Bool) -> Void = { _, _ in }
    var onInsertText: (String) -> Void = { _ in }
    /// Copies text without pasting (e.g. "Copy as rgb()"); becomes a new history item like any copy.
    var onCopyText: (String) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onResume: () -> Void = {}
    var onOpenPrivacySettings: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private var bag: AnyCancellable?
    /// True while the panel is visible (set by PanelController).
    var isLive = false {
        didSet { if isLive && !oldValue { recompute() } }
    }
    private var noticeTask: Task<Void, Never>?

    init(store: ClipStore) {
        self.store = store
        // Only re-render while the panel is on screen; a hidden panel re-rendering on every copy cost ~10% CPU in the soak.
        bag = store.$items.dropFirst().sink { [weak self] items in
            guard let self, self.isLive else { return }
            self.recompute(items: items)
        }
        recompute()
    }

    // MARK: Derived lists

    func recompute(items: [ClipItem]? = nil) {
        let items = items ?? store.items
        if tab == .clipboard {
            let all = items.filter(\.pinned) + items.filter { !$0.pinned }
            clips = Search.filter(all, query: query) { $0.searchText }
            glyphs = []
            recentCount = 0
            return
        }
        let source: [Glyph] = switch tab {
        case .clipboard: []
        case .emoji: CharacterSets.emoji
        case .symbols: CharacterSets.symbols
        case .kaomoji: CharacterSets.kaomoji
        }
        if query.isEmpty {
            let recents = Recents.get(tab.rawValue)
            let byValue = Dictionary(source.map { ($0.value, $0) }, uniquingKeysWith: { a, _ in a })
            let recentGlyphs = recents.compactMap { byValue[$0] }
            glyphs = recentGlyphs + source.filter { !recents.contains($0.value) }
            recentCount = recentGlyphs.count
        } else {
            glyphs = Search.filter(source, query: query) { $0.name + " " + $0.value }
            recentCount = 0
        }
    }

    var count: Int { tab == .clipboard ? clips.count : glyphs.count }

    // MARK: Lifecycle

    func reset() {
        query = ""
        tab = .clipboard
        selection = defaultSelection
        confirmingClear = false
        previewing = false
        commandHeld = false
        focusRequest += 1
    }

    func flash(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    // MARK: Keyboard

    enum Key { case up, down, left, right, enter, shiftEnter, escape, tab, backTab, delete, commandDelete, pin, quick(Int), preview, settings }

    /// Returns true if handled (so the event doesn't reach the search field).
    func handle(_ key: Key) -> Bool {
        if confirmingClear {
            switch key {
            case .enter: store.clearUnpinned(); confirmingClear = false; clamp(); return true
            case .escape: confirmingClear = false; return true
            default: return true
            }
        }
        if previewing {
            switch key {
            case .preview, .escape: previewing = false; return true
            case .up, .down: break   // keep browsing with the preview open
            case .enter, .shiftEnter: previewing = false
            default: return true
            }
        }
        let cols = tab == .clipboard ? 1 : tab.columns
        switch key {
        case .settings: onClose(); onOpenSettings()
        case .preview:
            if tab == .clipboard, selected != nil { previewing = true }
        case .up: move(-cols)
        case .down: move(cols)
        case .left where tab != .clipboard: move(-1)
        case .right where tab != .clipboard: move(1)
        case .left, .right: return false
        case .enter: activate(plain: plainByDefault)
        case .shiftEnter: activate(plain: !plainByDefault)
        case .escape:
            if query.isEmpty { onClose() } else { query = ""; selection = defaultSelection }
        case .tab: switchTab(1)
        case .backTab: switchTab(-1)
        case .delete:
            guard tab == .clipboard, query.isEmpty, let item = selected else { return false }
            store.delete(item.id); clamp()
        case .commandDelete:
            guard tab == .clipboard, store.items.contains(where: { !$0.pinned }) else { return true }
            confirmingClear = true
        case .pin:
            guard tab == .clipboard, let item = selected else { return true }
            store.togglePin(item.id)
            if let i = clips.firstIndex(where: { $0.id == item.id }) { selection = i }
        case .quick(let n):
            guard n - 1 < count else { return true }
            selection = n - 1
            activate(plain: plainByDefault)
        }
        return true
    }

    /// Like Win+V: start on the most recent copy, not on a pinned item (best match when searching).
    var defaultSelection: Int {
        tab == .clipboard && query.isEmpty ? (clips.firstIndex { !$0.pinned } ?? 0) : 0
    }

    var plainByDefault: Bool { Prefs.d.bool(forKey: Prefs.plainByDefault) }

    var selected: ClipItem? { tab == .clipboard && clips.indices.contains(selection) ? clips[selection] : nil }

    func activate(plain: Bool) {
        if tab == .clipboard {
            if let item = selected { onPaste(item, plain) }
        } else if glyphs.indices.contains(selection) {
            let g = glyphs[selection]
            Recents.add(g.value, tab: tab.rawValue)
            onInsertText(g.value)
            recompute()
        }
    }

    func activate(index: Int, plain: Bool) { selection = index; activate(plain: plain) }

    private func move(_ delta: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    func clamp() { selection = min(selection, max(count - 1, 0)) }

    private func switchTab(_ delta: Int) {
        let all = PanelTab.allCases
        let i = all.firstIndex(of: tab)!
        tab = all[(i + delta + all.count) % all.count]
        selection = 0
    }
}
