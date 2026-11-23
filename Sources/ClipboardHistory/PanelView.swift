import SwiftUI
import os
import Combine
import UniformTypeIdentifiers

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var searchFocused: Bool
    @AppStorage(Prefs.showFooter) private var showFooter = true

    var body: some View {
        VStack(spacing: 8) {
            searchField
            Picker("Category", selection: $model.tab) {
                ForEach(PanelTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: model.tab) { model.selection = model.defaultSelection }
            banner
            Group {
                if model.tab == .clipboard { ClipList(model: model) } else { GlyphGrid(model: model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if model.previewing, let item = model.selected {
                    PreviewPane(item: item, store: model.store)
                        .transition(.opacity)
                }
            }
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12), value: model.previewing)
            if model.confirmingClear { confirmBar } else if let notice = model.notice { noticeBar(notice) }
            else if showFooter || model.tab == .clipboard { footer }
        }
        .padding(8)
        .frame(minWidth: 320, idealWidth: 360, minHeight: 360, idealHeight: 480)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(searchPrompt, text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onChange(of: model.query) { model.selection = model.defaultSelection }
                .accessibilityLabel("Search")
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }

    private var searchPrompt: String {
        model.tab == .clipboard ? "Search clipboard" : "Search \(model.tab.rawValue.lowercased())"
    }

    @ViewBuilder private var banner: some View {
        switch model.banner {
        case .paused:
            bannerRow("pause.circle.fill", "Paused — not recording", button: "Resume", action: model.onResume)
        case .noClipboardAccess:
            bannerRow("lock.fill", "Clipboard History can't read the clipboard", button: "Open Settings", action: model.onOpenPrivacySettings)
        case .recovered:
            bannerRow("exclamationmark.triangle.fill", "History couldn't be loaded. A fresh one was started.", button: nil, action: {})
        case nil: EmptyView()
        }
    }

    private func bannerRow(_ symbol: String, _ text: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(.yellow)
            Text(text).font(.callout)
            Spacer()
            if let button { Button(button, action: action).controlSize(.small) }
        }
        .padding(8)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if showFooter {
                if model.plainByDefault { hint("↩", "Plain"); hint("⇧↩", "Formatted") }
                else { hint("↩", "Paste"); hint("⇧↩", "Plain") }
                if model.tab == .clipboard { hint("⌘P", "Pin"); hint("⌘Y", "Preview") }
            }
            Spacer()
            if model.tab == .clipboard && model.clips.contains(where: { !$0.pinned }) {
                Button { model.onClose(); model.onOpenSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).focusable(false).help("Settings (⌘,)").accessibilityLabel("Settings")
                Button("Clear All") { model.confirmingClear = true }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help("Clear all unpinned items (⌘⌫)")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) { Text(key).fontWeight(.medium); Text(label) }.accessibilityHidden(true)
    }

    private var confirmBar: some View {
        HStack {
            Text("Clear all unpinned items?").font(.callout)
            Spacer()
            Button("Cancel") { model.confirmingClear = false }.controlSize(.small)
            Button("Clear") { _ = model.handle(.enter) }.controlSize(.small).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 4)
    }

    private func noticeBar(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }
}

// MARK: - Clipboard list

private struct ClipList: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        if model.clips.isEmpty {
            EmptyState(query: model.query, hasItems: !model.store.items.isEmpty)
        } else {
            ClipTable(model: model, clips: model.clips, query: model.query, commandHeld: model.commandHeld)
        }
    }
}

/// The clip list as an NSTableView: layout and scrolling touch only on-screen rows, so arrowing through
/// 1,000+ items stays cheap (a SwiftUI LazyVStack re-laid out from the top on every step, C-09).
/// Each row is still the SwiftUI `ClipRow`, hosted in a reusable cell.
private struct ClipTable: NSViewRepresentable {
    let model: PanelModel
    let clips: [ClipItem]
    let query: String
    let commandHeld: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = PassiveTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.gridStyleMask = []
        let column = NSTableColumn(identifier: .init("clip"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.table = table
        context.coordinator.update(clips: clips, query: query, commandHeld: commandHeld)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(clips: clips, query: query, commandHeld: commandHeld)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum Row { case header(String), clip(Int) }
        let model: PanelModel
        weak var table: NSTableView?
        private var rows: [Row] = []
        private var rowOfClip: [Int] = []
        private var clips: [ClipItem] = []
        private var commandHeld = false
        private var bag: AnyCancellable?
        private var openBag: AnyCancellable?

        init(model: PanelModel) {
            self.model = model
            super.init()
            bag = model.cursor.$index.sink { [weak self] i in self?.select(i) }
            // Each time the panel opens (reset bumps focusRequest), start at the top like a fresh list.
            openBag = model.$focusRequest.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.table?.scroll(.zero)
                    if let self { self.select(self.model.cursor.index) }
                }
            }
        }

        func update(clips new: [ClipItem], query: String, commandHeld held: Bool) {
            let changed = new != clips
            let heldChanged = held != commandHeld
            clips = new
            commandHeld = held
            if changed {
                rows = []
                rowOfClip = []
                for (i, item) in new.enumerated() {
                    if i == 0 && item.pinned { rows.append(.header("Pinned")) }
                    if !item.pinned && (i == 0 || new[i - 1].pinned) { rows.append(.header(query.isEmpty ? "Recent" : "Results")) }
                    rowOfClip.append(rows.count)
                    rows.append(.clip(i))
                }
                table?.reloadData()
                table?.scroll(.zero)   // new list: start at the top (pinned section visible)
                select(model.cursor.index)
            } else if heldChanged {
                table?.reloadData()   // rare (⌘ pressed/released); keeps the scroll position
            }
        }

        /// Rows observe the cursor themselves (SelectableRow), so moving the selection only scrolls.
        private func select(_ i: Int) {
            guard let table, rowOfClip.indices.contains(i) else { return }
            let row = rowOfClip[i]
            // Jump, don't animate: scrollRowToVisible animates, and each animation frame re-lays out rows.
            let headerAbove = row > 0 && { if case .header = rows[row - 1] { return true } else { return false } }()
            var target = table.rect(ofRow: row)
            if headerAbove { target = target.union(table.rect(ofRow: row - 1)) }
            guard let clip = table.enclosingScrollView?.contentView, clip.bounds.height > 0 else { return }   // not laid out yet
            let visible = clip.bounds
            var y = visible.minY
            if target.minY < visible.minY { y = target.minY } else if target.maxY > visible.maxY { y = target.maxY - visible.height }
            guard y != visible.minY else { return }
            clip.scroll(to: NSPoint(x: visible.minX, y: max(0, y)))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if case .header = rows[row] { return 24 } else { return ClipRow.height }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: HostCell.id, owner: nil) as? HostCell ?? HostCell()
            switch rows[row] {
            case .header(let title):
                cell.fileURLs = []
                cell.host.rootView = AnyView(SectionHeader(title: title))
            case .clip(let i):
                let item = clips[i]
                let model = model
                cell.onClick = { [weak model] plain in model?.activate(index: i, plain: plain) }
                cell.fileURLs = item.kind == .files
                    ? (model.store.representations(of: item).first { $0.type == ClipBuilder.fileURL }
                        .map { ClipBuilder.fileURLs(from: $0.data) } ?? [])
                    : []
                cell.host.rootView = AnyView(
                    SelectableRow(cursor: model.cursor, index: i) { selected in
                        ClipRow(item: item, index: i, selected: selected, showNumber: self.commandHeld && i < 9, store: model.store,
                                activate: { [weak model] plain in model?.activate(index: i, plain: plain) },
                                remove: { [weak model] in model?.store.delete(item.id); model?.clamp() })
                            .equatable()
                    }
                    .contextMenu { RowMenu(item: item, index: i, model: model) }
                    .id(item.id))   // fresh hover state per item when a cell is reused
            }
            return cell
        }
    }
}

/// Never takes keyboard focus, so typing keeps going to the search field.
private final class PassiveTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

private let dragLog = Logger(subsystem: "app.clipboard-history", category: "drag")

/// Sits over a file-list row. A click passes through to the row (paste); a drag starts a session with every file (S-10).
private final class FileDragCatcher: NSView, NSDraggingSource {
    var fileURLs: [URL] = []
    private var down: NSEvent?

    // Clipboard History is never the active app (non-activating panel), so without this the first click is swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { down = event }

    override func mouseDragged(with event: NSEvent) {
        guard let start = down, hypot(event.locationInWindow.x - start.locationInWindow.x,
                                      event.locationInWindow.y - start.locationInWindow.y) > 3 else { return }
        down = nil
        let p = convert(event.locationInWindow, from: nil)
        let items = fileURLs.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: p.x - 16 + CGFloat(i * 6), y: p.y - 16 - CGFloat(i * 6), width: 32, height: 32),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        dragLog.info("drag session started with \(items.count, privacy: .public) items, session \(session.draggingSequenceNumber, privacy: .public)")
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragLog.info("drag ended, operation \(operation.rawValue, privacy: .public)")
    }

    /// Plain click (no drag): paste, same as clicking any other row.
    var onClick: (_ plain: Bool) -> Void = { _ in }

    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        down = nil
        onClick(event.modifierFlags.contains(.option) != Prefs.d.bool(forKey: Prefs.plainByDefault))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let host = superview?.subviews.first else { return }
        (host.hitTest(host.superview!.convert(event.locationInWindow, from: nil)) ?? host).rightMouseDown(with: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

private final class HostCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("HostCell")
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    /// Files of a file-list item; when set, a drag from this row carries all of them (S-10).
    var fileURLs: [URL] = [] { didSet { dragCatcher.fileURLs = fileURLs; dragCatcher.isHidden = fileURLs.count < 2 } }
    var onClick: (Bool) -> Void { get { dragCatcher.onClick } set { dragCatcher.onClick = newValue } }
    private let dragCatcher = FileDragCatcher()

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        host.sizingOptions = []   // the table fixes row height; skip intrinsic-size constraint churn on every update
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        // Transparent view on top: SwiftUI's hosting view swallows mouseDragged, so a subclass override never ran.
        dragCatcher.translatesAutoresizingMaskIntoConstraints = false
        dragCatcher.isHidden = true
        addSubview(dragCatcher)
        NSLayoutConstraint.activate([
            dragCatcher.leadingAnchor.constraint(equalTo: leadingAnchor), dragCatcher.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragCatcher.topAnchor.constraint(equalTo: topAnchor), dragCatcher.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Observes only the cursor, so a selection change re-renders the rows on screen, not the list.
private struct SelectableRow<Content: View>: View {
    @ObservedObject var cursor: Cursor
    let index: Int
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(cursor.index == index) }
}

/// Larger look at the selected item (⌘Y), like Quick Look: full text, a big image, all files, or a big swatch.
private struct PreviewPane: View {
    let item: ClipItem
    let store: ClipStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(item.kind.label, systemImage: item.kind.symbol).font(.headline)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text("⌘Y or Esc to close · ↑↓ to browse").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .padding(4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of \(item.kind.label)")
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image:
            if let rep = store.representations(of: item).first(where: { [ClipBuilder.png, ClipBuilder.jpeg].contains($0.type) }),
               let image = NSImage(data: rep.data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(item.preview).font(.caption).foregroundStyle(.secondary)
            }
        case .files:
            let urls = store.representations(of: item).first { $0.type == ClipBuilder.fileURL }
                .map { ClipBuilder.fileURLs(from: $0.data) } ?? []
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(urls, id: \.self) { url in
                        Label { Text(url.path).lineLimit(1).truncationMode(.middle) } icon: {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                        }
                    }
                }
            }
        case .color:
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 8).fill(Color(hex: item.preview) ?? .gray)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                Text(item.preview).font(.title3.monospaced()).textSelection(.enabled)
                if let rgb = ColorFormat.rgb(item.preview), let hsl = ColorFormat.hsl(item.preview) {
                    Text(rgb).monospaced().textSelection(.enabled)
                    Text(hsl).monospaced().textSelection(.enabled)
                }
            }
        default:
            ScrollView {
                // ponytail: shows the first 100 KB; a 10 MB paste would make Text layout slow
                Text(String((store.plainText(of: item) ?? item.preview).prefix(100_000)))
                    .font(.body.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Right-click menu, like the "…" menu on Win+V items.
private struct RowMenu: View {
    let item: ClipItem
    let index: Int
    let model: PanelModel
    var body: some View {
        Button("Paste") { model.activate(index: index, plain: false) }
        Button("Paste as Plain Text") { model.activate(index: index, plain: true) }
        Button("Preview") { model.selection = index; model.previewing = true }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { model.store.togglePin(item.id) }
        Button("Delete") { model.store.delete(item.id); model.clamp() }
        Divider()
        Button("Clear All Unpinned…") { model.confirmingClear = true }
        if item.kind == .color, let rgb = ColorFormat.rgb(item.preview), let hsl = ColorFormat.hsl(item.preview) {
            Divider()
            Button("Copy as \(rgb)") { model.onCopyText(rgb) }
            Button("Copy as \(hsl)") { model.onCopyText(hsl) }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct EmptyState: View {
    let query: String
    let hasItems: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: hasItems ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: 32)).foregroundStyle(.tertiary)
            Text(hasItems ? "No results for “\(query)”" : "Nothing copied yet").font(.headline)
            if !hasItems {
                Text("Copy something and it will show up here.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Equatable so SwiftUI skips re-rendering rows whose data didn't change (selection moves only touch two rows).
struct ClipRow: View, @MainActor Equatable {
    let item: ClipItem
    let index: Int
    let selected: Bool
    let showNumber: Bool
    let store: ClipStore
    let activate: (_ plain: Bool) -> Void
    let remove: () -> Void
    @State private var hovering = false

    static let height: CGFloat = 46

    static func == (a: ClipRow, b: ClipRow) -> Bool {
        a.item == b.item && a.index == b.index && a.selected == b.selected && a.showNumber == b.showNumber
    }
    @AppStorage(Prefs.showAppIcons) private var showAppIcons = true

    var body: some View {
        HStack(spacing: 8) {
            leading.frame(width: 20, height: 20)
            content.frame(maxWidth: .infinity, alignment: .leading)
            // Constant structure: adding/removing focusable buttons on each selection change made AppKit
            // rebuild the key-view loop across every table row (the scroll hot path at 1,000 items).
            ZStack(alignment: .trailing) {
                HStack(spacing: 4) {
                    if item.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(Self.relative(item.lastUsedAt)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .opacity(hovering || selected ? 0 : 1)
                actions
                    .opacity(hovering || selected ? 1 : 0)
                    .allowsHitTesting(hovering || selected)
            }
            if showNumber {
                Text("⌘\(index + 1)").font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
            }
        }
        .padding(.horizontal, 8)
        // Fixed height: lets LazyVStack place rows without measuring text (scrollTo on 1,000 rows was the hot path).
        .frame(height: Self.height)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : (hovering ? Color.primary.opacity(0.06) : .clear),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { activate(NSEvent.modifierFlags.contains(.option) != Prefs.d.bool(forKey: Prefs.plainByDefault)) }
        .onDrag { dragProvider() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { activate(false) }
        .accessibilityAction(named: "Paste as plain text") { activate(true) }
        .accessibilityAction(named: item.pinned ? "Unpin" : "Pin") { store.togglePin(item.id) }
        .accessibilityAction(named: "Delete") { remove() }
    }

    @ViewBuilder private var leading: some View {
        if item.kind == .color, let color = Color(hex: item.preview) {
            RoundedRectangle(cornerRadius: 4).fill(color)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        } else if showAppIcons, let icon = IconCache.appIcon(item.sourceBundleID) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: item.kind.symbol).foregroundStyle(selected ? Color.white : Color.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        if item.kind == .image, let thumb = IconCache.thumbnail(store.thumbnailURL(item)) {
            HStack(spacing: 8) {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 64, maxHeight: 32).clipShape(RoundedRectangle(cornerRadius: 3))
                    .frame(width: 64, alignment: .leading)
                Text(item.preview).font(.callout).lineLimit(1)
            }
        } else if item.kind == .files {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc").foregroundStyle(selected ? Color.white : Color.secondary)
                Text(item.preview).lineLimit(2).truncationMode(.middle)
            }
        } else {
            Text(item.preview).lineLimit(2).truncationMode(.tail)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { store.togglePin(item.id) } label: {
                Image(systemName: item.pinned ? "pin.slash" : "pin")
            }
            .help(item.pinned ? "Unpin (⌘P)" : "Pin (⌘P)")
            .accessibilityLabel(item.pinned ? "Unpin" : "Pin")
            Button { remove() } label: { Image(systemName: "trash") }
                .help("Delete (⌫)")
                .accessibilityLabel("Delete")
        }
        .buttonStyle(.plain)
        .focusable(false)   // keyboard users have ⌘P / ⌫; VoiceOver uses the row's actions
        .accessibilityHidden(true)
        .foregroundStyle(selected ? Color.white : Color.secondary)
    }

    private var accessibilityText: String { Self.spokenDescription(item) }

    /// What VoiceOver reads for an item, on the row and in selection announcements.
    static func spokenDescription(_ item: ClipItem) -> String {
        var parts = [item.kind.label, String(item.preview.prefix(200)), "copied \(relative(item.lastUsedAt, full: true))"]
        if let app = IconCache.appName(item.sourceBundleID) { parts.append("from \(app)") }
        if item.pinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }


    private func dragProvider() -> NSItemProvider {
        let reps = store.representations(of: item)
        if let files = reps.first(where: { $0.type == ClipBuilder.fileURL }),
           let url = ClipBuilder.fileURLs(from: files.data).first {
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        if let img = reps.first(where: { [ClipBuilder.png, ClipBuilder.jpeg].contains($0.type) }) {
            return NSItemProvider(item: img.data as NSData, typeIdentifier: img.type)
        }
        return NSItemProvider(object: (store.plainText(of: item) ?? item.preview) as NSString)
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()
    private static let fullFormatter = RelativeDateTimeFormatter()

    static func relative(_ date: Date, full: Bool = false) -> String {
        if Date().timeIntervalSince(date) < 60 { return "now" }
        return (full ? fullFormatter : formatter).localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Glyph grid

private struct GlyphGrid: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let glyphs = model.glyphs
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: model.tab.columns)
        if glyphs.isEmpty {
            Text("No results for “\(model.query)”").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.recentCount > 0 { header("Recent") }
                    LazyVGrid(columns: cols, spacing: 2) {
                        ForEach(Array(glyphs.enumerated()), id: \.offset) { i, g in
                            SelectableRow(cursor: model.cursor, index: i) { selected in
                                GlyphCell(glyph: g, selected: selected, tab: model.tab,
                                          activate: { [weak model] in model?.activate(index: i, plain: true) })
                                    .equatable()
                            }
                            .id(i)
                        }
                    }
                }
                .onReceive(model.cursor.$index) { proxy.scrollTo($0) }
            }
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.top, 4)
    }
}

private struct GlyphCell: View, @MainActor Equatable {
    let glyph: Glyph
    let selected: Bool
    let tab: PanelTab
    let activate: () -> Void

    static func == (a: GlyphCell, b: GlyphCell) -> Bool { a.glyph == b.glyph && a.selected == b.selected && a.tab == b.tab }

    var body: some View {
        Text(glyph.value)
            .font(tab == .emoji ? .system(size: 24) : (tab == .kaomoji ? .callout : .title2))
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture { activate() }
            .help(glyph.name.capitalized)
            .accessibilityLabel(glyph.name)
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Caches

@MainActor
enum IconCache {
    private static let images = NSCache<NSString, NSImage>()
    private static var names: [String: String] = [:]

    static func appIcon(_ bundleID: String?) -> NSImage? {
        guard let id = bundleID else { return nil }
        if let hit = images.object(forKey: id as NSString) { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let icon = rasterize(NSWorkspace.shared.icon(forFile: url.path), points: 20)
        images.setObject(icon, forKey: id as NSString)
        return icon
    }

    static func appName(_ bundleID: String?) -> String? {
        guard let id = bundleID else { return nil }
        if let n = names[id] { return n }
        let n = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        names[id] = n
        return n
    }

    /// Workspace icons are lazy multi-resolution images that re-rasterize on every SwiftUI render
    /// (seen in the soak profile); draw once into a fixed 2× bitmap instead.
    static func rasterize(_ image: NSImage, points: CGFloat) -> NSImage {
        let px = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }

    static func thumbnail(_ url: URL) -> NSImage? {
        let key = url.path as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        images.setObject(img, forKey: key)
        return img
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let rgb = s.count == 8 ? v >> 8 : v
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
