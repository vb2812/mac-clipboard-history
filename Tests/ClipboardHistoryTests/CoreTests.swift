import XCTest
import AppKit
@testable import ClipboardHistory

@MainActor
final class StoreTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-history-test-\(UUID().uuidString)")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func make(_ text: String, store: ClipStore, at date: Date = Date()) throws -> ClipItem {
        let id = UUID()
        let cap = Capture(reps: [Representation(type: ClipBuilder.plain, data: Data(text.utf8))], sourceBundleID: "com.test", date: date)
        let item = try XCTUnwrap(ClipBuilder.build(cap, id: id, dir: store.blobDir(id)))
        store.insert(item)
        return item
    }

    func testInsertOrderAndPersistence() throws {
        var store = ClipStore(root: dir)
        _ = try make("one", store: store); _ = try make("two", store: store)
        XCTAssertEqual(store.items.map(\.preview), ["two", "one"])
        store = ClipStore(root: dir)
        XCTAssertEqual(store.items.map(\.preview), ["two", "one"], "reloads from SQLite in recency order")
    }

    func testDedupeMovesToTop() throws {
        let store = ClipStore(root: dir)
        _ = try make("a", store: store); _ = try make("b", store: store); _ = try make("a", store: store)
        XCTAssertEqual(store.items.map(\.preview), ["a", "b"])
    }

    func testEvictionKeepsPinned() throws {
        let store = ClipStore(root: dir, limit: 3)
        let first = try make("pinned", store: store)
        store.togglePin(first.id)
        for i in 0..<10 { _ = try make("x\(i)", store: store) }
        XCTAssertEqual(store.items.filter { !$0.pinned }.count, 3)
        XCTAssertTrue(store.items.contains { $0.id == first.id && $0.pinned })
        XCTAssertEqual(store.items.filter { !$0.pinned }.map(\.preview), ["x9", "x8", "x7"])
    }

    func testClearUnpinnedKeepsPinnedAcrossRestart() throws {
        var store = ClipStore(root: dir)
        let keep = try make("keep", store: store)
        store.togglePin(keep.id)
        _ = try make("drop", store: store)
        store.clearUnpinned()
        XCTAssertEqual(store.items.map(\.preview), ["keep"])
        store = ClipStore(root: dir)
        XCTAssertEqual(store.items.map(\.preview), ["keep"])
        XCTAssertTrue(store.items[0].pinned)
        store.clearEverything()
        XCTAssertTrue(ClipStore(root: dir).items.isEmpty)
    }

    func testDeleteRemovesBlobs() async throws {
        let store = ClipStore(root: dir)
        let item = try make("bye", store: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.blobDir(item.id).path))
        store.delete(item.id)
        XCTAssertTrue(store.items.isEmpty)
        let gone = expectation(description: "blob dir removed")
        Task { for _ in 0..<50 where FileManager.default.fileExists(atPath: store.blobDir(item.id).path) { try? await Task.sleep(for: .milliseconds(20)) }; gone.fulfill() }
        await fulfillment(of: [gone], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.blobDir(item.id).path))
    }

    func testCorruptDatabaseIsQuarantined() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 4096).write(to: dir.appendingPathComponent("history.sqlite"))
        let store = ClipStore(root: dir)
        XCTAssertTrue(store.recoveredFromCorruption)
        XCTAssertTrue(store.items.isEmpty)
        _ = try make("works again", store: store)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("history.sqlite.corrupt-") }, "\(files)")
        XCTAssertEqual(ClipStore(root: dir).items.count, 1)
    }

    /// Simulates kill -9 mid-write: an uncommitted transaction left in the WAL must roll back cleanly.
    func testUncommittedWriteIsRolledBackAfterCrash() throws {
        do {
            let store = ClipStore(root: dir)
            _ = try make("committed", store: store)
        }
        let path = dir.appendingPathComponent("history.sqlite").path
        let crashed = try Database(path: path)
        try crashed.exec("BEGIN; INSERT INTO items VALUES ('x',0,0,'text','torn','torn',NULL,0,0,'h','public.utf8-plain-text');")
        // No COMMIT: abandon the connection the way a killed process would (its WAL frames stay uncommitted).
        let reopened = ClipStore(root: dir)
        XCTAssertFalse(reopened.recoveredFromCorruption)
        XCTAssertEqual(reopened.items.map(\.preview), ["committed"])
        _ = crashed
    }

    /// Disk full / unwritable blob dir: build throws, nothing half-inserted.
    func testUnwritableBlobDirThrows() throws {
        let store = ClipStore(root: dir)
        let blocker = dir.appendingPathComponent("blocker")
        try Data().write(to: blocker)   // a file where a directory is expected
        let cap = Capture(reps: [Representation(type: ClipBuilder.plain, data: Data("x".utf8))], sourceBundleID: nil)
        XCTAssertThrowsError(try ClipBuilder.build(cap, dir: blocker.appendingPathComponent("item")))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testFilesArePrivate() throws {
        umask(0o077)
        let store = ClipStore(root: dir)
        let item = try make("secret-ish", store: store)
        let blob = store.blobDir(item.id).appendingPathComponent("0").path
        let perms = try FileManager.default.attributesOfItem(atPath: blob)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let dbPerms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("history.sqlite").path)[.posixPermissions] as? Int
        XCTAssertEqual(dbPerms, 0o600)
    }

    func testExpireRemovesOnlyOldUnpinned() throws {
        let store = ClipStore(root: dir)
        let old = try make("old", store: store, at: Date().addingTimeInterval(-7200))
        let oldPinned = try make("old pinned", store: store, at: Date().addingTimeInterval(-7200))
        store.togglePin(oldPinned.id)
        _ = try make("fresh", store: store)
        store.expire(before: Date().addingTimeInterval(-3600))
        XCTAssertEqual(Set(store.items.map(\.preview)), ["old pinned", "fresh"])
        XCTAssertFalse(store.items.contains { $0.id == old.id })
    }

    func testSchemaVersionSet() throws {
        _ = ClipStore(root: dir)
        let db = try Database(path: dir.appendingPathComponent("history.sqlite").path)
        XCTAssertEqual(db.userVersion, ClipStore.schemaVersion)
    }

    func testPlainTextFallbacks() throws {
        let store = ClipStore(root: dir)
        let id = UUID()
        let rtf = Data(#"{\rtf1\ansi {\b Bold} text}"#.utf8)
        let item = try XCTUnwrap(ClipBuilder.build(Capture(reps: [Representation(type: ClipBuilder.rtf, data: rtf)], sourceBundleID: nil), id: id, dir: store.blobDir(id)))
        store.insert(item)
        XCTAssertEqual(item.kind, .richText)
        XCTAssertEqual(store.plainText(of: item)?.trimmingCharacters(in: .whitespacesAndNewlines), "Bold text")
    }
}

final class BuilderTests: XCTestCase {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-history-builder-\(UUID().uuidString)")
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func build(_ reps: [Representation]) throws -> ClipItem {
        try XCTUnwrap(ClipBuilder.build(Capture(reps: reps, sourceBundleID: nil), dir: dir.appendingPathComponent(UUID().uuidString)))
    }
    func text(_ s: String) -> Representation { Representation(type: ClipBuilder.plain, data: Data(s.utf8)) }

    func testKinds() throws {
        XCTAssertEqual(try build([text("hello")]).kind, .text)
        XCTAssertEqual(try build([text("https://apple.com/mac")]).kind, .url)
        XCTAssertEqual(try build([text("not a url https://x.com")]).kind, .text)
        XCTAssertEqual(try build([text("#FF6A00")]).kind, .color)
        XCTAssertEqual(try build([text("#abc")]).kind, .color)
        XCTAssertEqual(try build([text("hi"), Representation(type: ClipBuilder.html, data: Data("<b>hi</b>".utf8))]).kind, .richText)
        let files = try build([Representation(type: ClipBuilder.fileURL, data: Data("file:///a.pdf\nfile:///b.png\nfile:///c\nfile:///d".utf8))])
        XCTAssertEqual(files.kind, .files)
        XCTAssertEqual(files.preview, "a.pdf, b.png and 2 more")
    }

    func testImageThumbnailAndTiffConversion() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 480, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let tiff = try XCTUnwrap(rep.tiffRepresentation)
        let id = UUID()
        let out = dir.appendingPathComponent(id.uuidString)
        let item = try XCTUnwrap(ClipBuilder.build(Capture(reps: [Representation(type: ClipBuilder.tiff, data: tiff)], sourceBundleID: nil), id: id, dir: out))
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.types, [ClipBuilder.png], "TIFF-only images are stored as PNG")
        XCTAssertTrue(item.preview.hasPrefix("640×480 · PNG"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("thumb.png").path))
    }

    func testLongTextPreviewAndSearchCaps() throws {
        let big = String(repeating: "Ünïcode   word\n", count: 100_000)   // ~1.5 MB
        let item = try build([text(big)])
        XCTAssertLessThanOrEqual(item.preview.count, ClipBuilder.previewLimit)
        XCTAssertLessThanOrEqual(item.searchText.count, ClipBuilder.searchLimit)
        XCTAssertFalse(item.preview.contains("\n"))
        XCTAssertTrue(item.searchText.hasPrefix("unicode"), "folded for diacritic/case-insensitive search")
    }

    func testHashDedupesIdenticalText() throws {
        XCTAssertEqual(try build([text("same")]).contentHash, try build([text("same")]).contentHash)
        XCTAssertNotEqual(try build([text("same")]).contentHash, try build([text("diff")]).contentHash)
    }
}

final class PrivacyTests: XCTestCase {
    func v(_ types: [String], app: String? = "com.apple.Safari", paused: Bool = false) -> PrivacyFilter.Verdict {
        PrivacyFilter.verdict(types: types, sourceBundleID: app, paused: paused, excludedApps: Set(PrivacyFilter.defaultExcludedApps))
    }
    func testMarkers() {
        XCTAssertEqual(v(["public.utf8-plain-text"]), .capture)
        XCTAssertEqual(v(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]), .concealed)
        XCTAssertEqual(v(["org.nspasteboard.TransientType"]), .concealed)
        XCTAssertEqual(v(["org.nspasteboard.AutoGeneratedType"]), .concealed)
        XCTAssertEqual(v(["com.agilebits.onepassword"]), .concealed)
    }
    func testExcludedAppAndPause() {
        XCTAssertEqual(v(["public.utf8-plain-text"], app: "com.bitwarden.desktop"), .excludedApp)
        XCTAssertEqual(v(["public.utf8-plain-text"], paused: true), .paused)
    }
}

@MainActor
final class ShortcutRuleTests: XCTestCase {
    func testRules() {
        XCTAssertEqual(ShortcutRules.check(description: "V", modifiers: []), .block("Add ⌘, ⌥ or ⌃ so the shortcut doesn't type a character."))
        XCTAssertEqual(ShortcutRules.check(description: "⇧V", modifiers: [.shift]), .block("Add ⌘, ⌥ or ⌃ so the shortcut doesn't type a character."))
        if case .block = ShortcutRules.check(description: "⌘V", modifiers: [.command]) {} else { XCTFail("⌘V must be blocked") }
        if case .warn = ShortcutRules.check(description: "⇧⌘V", modifiers: [.command, .shift]) {} else { XCTFail("⇧⌘V should warn") }
        XCTAssertEqual(ShortcutRules.check(description: "⌃⌥⇧⌘F12", modifiers: [.control, .option, .shift, .command]), .ok)
        XCTAssertEqual(ShortcutRules.check(description: "⌃⌥Space", modifiers: [.control, .option]), .ok)
    }
}

final class ColorFormatTests: XCTestCase {
    func testConversions() {
        XCTAssertEqual(ColorFormat.rgb("#FF6A00"), "rgb(255, 106, 0)")
        XCTAssertEqual(ColorFormat.hsl("#FF6A00"), "hsl(25, 100%, 50%)")
        XCTAssertEqual(ColorFormat.rgb("#abc"), "rgb(170, 187, 204)")
        XCTAssertEqual(ColorFormat.hsl("#808080"), "hsl(0, 0%, 50%)")
        XCTAssertNil(ColorFormat.rgb("FF6A00"))
    }
}

final class SearchTests: XCTestCase {
    func testRankingPrefixWordSubstringThenRecency() {
        let items = ["the build log", "rebuild", "build it", "nothing", "Build system"]
        let out = Search.filter(items, query: "build") { Search.fold($0) }
        XCTAssertEqual(out, ["build it", "Build system", "the build log", "rebuild"])
    }
    func testDiacriticInsensitive() {
        XCTAssertEqual(Search.filter(["café au lait"], query: "CAFE") { Search.fold($0) }, ["café au lait"])
    }
    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(Search.filter(["a", "b"], query: "  ") { $0 }, ["a", "b"])
    }
}

@MainActor
final class PositionTests: XCTestCase {
    let screens = [NSRect(x: 0, y: 0, width: 1440, height: 875), NSRect(x: 1440, y: 0, width: 1920, height: 1055)]
    let size = NSSize(width: 360, height: 480)

    func testAtMouseOnSecondScreen() {
        let o = PanelController.origin(for: size, caret: nil, mouse: NSPoint(x: 2000, y: 900), screens: screens)
        XCTAssertEqual(o, NSPoint(x: 2000, y: 420))
    }
    func testClampedToEdges() {
        let o = PanelController.origin(for: size, caret: nil, mouse: NSPoint(x: 1430, y: 100), screens: screens)
        XCTAssertEqual(o.x, 1440 - 360 - 8); XCTAssertEqual(o.y, 8)
    }
    func testFlipsAboveCaretNearBottom() {
        let caret = NSRect(x: 100, y: 60, width: 2, height: 16)
        let o = PanelController.origin(for: size, caret: caret, mouse: .zero, screens: screens)
        XCTAssertEqual(o.y, caret.maxY + 4)
    }
    func testCaretLookupIsTimeBoxed() {
        let start = Date()
        let slow: Int? = PanelController.withinBudget(0.04) { Thread.sleep(forTimeInterval: 0.5); return 1 }
        XCTAssertNil(slow, "a slow app must not delay the panel")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(PanelController.withinBudget(0.5) { 7 }, 7)
    }

    func testFieldAnchorFallback() {
        let editor = PanelController.fieldAnchorRect(role: "AXTextArea", frame: CGRect(x: 100, y: 200, width: 800, height: 600))
        XCTAssertEqual(editor, CGRect(x: 108, y: 208, width: 1, height: 20))
        let field = PanelController.fieldAnchorRect(role: "AXTextField", frame: CGRect(x: 10, y: 10, width: 200, height: 22))
        XCTAssertEqual(field, CGRect(x: 18, y: 10, width: 1, height: 20))
        XCTAssertNil(PanelController.fieldAnchorRect(role: "AXButton", frame: CGRect(x: 0, y: 0, width: 80, height: 30)))
        XCTAssertNil(PanelController.fieldAnchorRect(role: "AXTextField", frame: CGRect(x: 0, y: 0, width: 5, height: 5)))
        // VS Code: zero-width hidden textarea at the caret (measured 640,134 0×18)
        XCTAssertEqual(PanelController.fieldAnchorRect(role: "AXTextArea", frame: CGRect(x: 640, y: 134, width: 0, height: 18)),
                       CGRect(x: 640, y: 134, width: 1, height: 18))
    }

    func testBelowCaret() {
        let caret = NSRect(x: 300, y: 700, width: 2, height: 16)
        let o = PanelController.origin(for: size, caret: caret, mouse: .zero, screens: screens)
        XCTAssertEqual(o, NSPoint(x: 300, y: 700 - 4 - 480))
    }
}

@MainActor
final class PanelModelTests: XCTestCase {
    var dir: URL!
    var store: ClipStore!
    var model: PanelModel!
    var pasted: [(String, Bool)] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-history-pm-\(UUID().uuidString)")
        store = ClipStore(root: dir, limit: 50)
        for s in ["pinned one", "old", "middle", "newest"] {
            let id = UUID()
            store.insert(try XCTUnwrap(ClipBuilder.build(Capture(reps: [Representation(type: ClipBuilder.plain, data: Data(s.utf8))], sourceBundleID: nil), id: id, dir: store.blobDir(id))))
        }
        store.togglePin(store.items.first { $0.preview == "pinned one" }!.id)
        model = PanelModel(store: store)
        model.isLive = true
        model.onPaste = { [unowned self] item, plain in self.pasted.append((item.preview, plain)) }
        model.reset()
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        for t in PanelTab.allCases { UserDefaults.standard.removeObject(forKey: "recents.\(t.rawValue)") }
    }

    func testDefaultSelectionIsNewestNotPinned() {
        XCTAssertEqual(model.clips.map(\.preview), ["pinned one", "newest", "middle", "old"])
        XCTAssertEqual(model.selected?.preview, "newest")
    }
    func testArrowsReturnAndPlain() {
        _ = model.handle(.down); _ = model.handle(.enter)
        _ = model.handle(.up); _ = model.handle(.up); _ = model.handle(.up); _ = model.handle(.shiftEnter)
        XCTAssertEqual(pasted.map(\.0), ["middle", "pinned one"])
        XCTAssertEqual(pasted.map(\.1), [false, true])
    }
    func testPlainByDefaultSwapsReturnAndShiftReturn() {
        UserDefaults.standard.set(true, forKey: Prefs.plainByDefault)
        defer { UserDefaults.standard.removeObject(forKey: Prefs.plainByDefault) }
        _ = model.handle(.enter); _ = model.handle(.shiftEnter); _ = model.handle(.quick(1))
        XCTAssertEqual(pasted.map(\.1), [true, false, true])
    }

    func testQuickPaste() {
        _ = model.handle(.quick(3))
        XCTAssertEqual(pasted.first?.0, "middle")
        XCTAssertTrue(model.handle(.quick(9)), "out of range is swallowed, not passed to the search field")
        XCTAssertEqual(pasted.count, 1)
    }
    func testDeleteOnlyWhenSearchEmpty() {
        model.query = "mid"
        XCTAssertFalse(model.handle(.delete), "⌫ edits the search text when searching")
        model.query = ""
        model.selection = model.defaultSelection
        XCTAssertTrue(model.handle(.delete))
        XCTAssertFalse(store.items.contains { $0.preview == "newest" })
    }
    func testPinToggleKeepsSelectionOnItem() {
        _ = model.handle(.pin)
        XCTAssertEqual(model.selected?.preview, "newest")
        XCTAssertTrue(model.selected?.pinned ?? false)
    }
    func testClearAllConfirmsAndKeepsPinned() {
        _ = model.handle(.commandDelete)
        XCTAssertTrue(model.confirmingClear)
        _ = model.handle(.enter)
        XCTAssertEqual(store.items.map(\.preview), ["pinned one"])
        XCTAssertTrue(pasted.isEmpty, "Return confirms the clear, it doesn't paste")
    }
    func testTabCyclesAndEscape() {
        _ = model.handle(.tab); XCTAssertEqual(model.tab, .emoji)
        _ = model.handle(.backTab); _ = model.handle(.backTab); XCTAssertEqual(model.tab, .kaomoji)
        var closed = false
        model.onClose = { closed = true }
        model.query = "x"
        _ = model.handle(.escape); XCTAssertEqual(model.query, ""); XCTAssertFalse(closed)
        _ = model.handle(.escape); XCTAssertTrue(closed)
    }
    func testPreviewKeys() {
        var closed = false
        model.onClose = { closed = true }
        _ = model.handle(.preview); XCTAssertTrue(model.previewing)
        _ = model.handle(.down); XCTAssertTrue(model.previewing, "↓ browses with the preview open")
        XCTAssertEqual(model.selected?.preview, "middle")
        _ = model.handle(.escape); XCTAssertFalse(model.previewing); XCTAssertFalse(closed, "first Esc closes only the preview")
        _ = model.handle(.preview); _ = model.handle(.enter)
        XCTAssertFalse(model.previewing); XCTAssertEqual(pasted.first?.0, "middle")
    }

    func testSearchFindsAndRanks() {
        model.query = "NEW"
        XCTAssertEqual(model.clips.map(\.preview), ["newest"])
    }
    func testEmojiSearchAndRecents() {
        model.tab = .emoji
        model.query = "grinning face"
        XCTAssertTrue(model.glyphs.contains { $0.value == "😀" })
        var inserted: String?
        model.onInsertText = { inserted = $0 }
        model.selection = model.glyphs.firstIndex { $0.value == "😀" }!
        _ = model.handle(.enter)
        XCTAssertEqual(inserted, "😀")
        model.query = ""
        XCTAssertEqual(model.glyphs.first?.value, "😀", "recently used first")
    }
}

@MainActor
final class PasteboardRoundTripTests: XCTestCase {
    func testWriteThenReadPreservesTypes() throws {
        let pb = NSPasteboard(name: .init("clipboard-history-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let reps = [Representation(type: ClipBuilder.plain, data: Data("hi".utf8)),
                    Representation(type: ClipBuilder.rtf, data: Data(#"{\rtf1 {\b hi}}"#.utf8))]
        let count = PasteService.write(reps, plainText: "hi", asPlain: false, to: pb)
        guard case .captured(let cap) = PasteboardMonitor.read(expectedCount: count, maxBytes: 1_000_000, source: nil, pasteboard: pb)
        else { return XCTFail("nothing read") }
        XCTAssertEqual(Set(cap.reps.map(\.type)), [ClipBuilder.plain, ClipBuilder.rtf])
        // Plain-text paste writes only text.
        let c2 = PasteService.write(reps, plainText: "hi", asPlain: true, to: pb)
        guard case .captured(let cap2) = PasteboardMonitor.read(expectedCount: c2, maxBytes: 1_000_000, source: nil, pasteboard: pb)
        else { return XCTFail() }
        XCTAssertEqual(cap2.reps.map(\.type), [ClipBuilder.plain])
    }

    func testFileListRoundTrip() throws {
        let pb = NSPasteboard(name: .init("clipboard-history-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let urls = [URL(fileURLWithPath: "/Applications/Safari.app"), URL(fileURLWithPath: "/etc/hosts")]
        pb.clearContents(); pb.writeObjects(urls as [NSURL])
        guard case .captured(let cap) = PasteboardMonitor.read(expectedCount: pb.changeCount, maxBytes: 1_000_000, source: nil, pasteboard: pb)
        else { return XCTFail() }
        XCTAssertEqual(ClipBuilder.fileURLs(from: cap.reps[0].data).map(\.path), urls.map(\.path))
        let c = PasteService.write(cap.reps, plainText: nil, asPlain: false, to: pb)
        XCTAssertEqual(pb.changeCount, c)
        XCTAssertEqual((pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.path), urls.map(\.path))
    }

    func testFiveThousandFileList() throws {
        let pb = NSPasteboard(name: .init("clipboard-history-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-history-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Real files: the pasteboard refuses file URLs it can't issue sandbox extensions for.
        let urls = (0..<5000).map { folder.appendingPathComponent("file\($0).txt") }
        for u in urls { FileManager.default.createFile(atPath: u.path, contents: nil) }
        pb.clearContents(); pb.writeObjects(urls as [NSURL])
        let start = Date()
        let outcome = PasteboardMonitor.read(expectedCount: pb.changeCount, maxBytes: 100_000_000, source: nil, pasteboard: pb)
        guard case .captured(let cap) = outcome else { return XCTFail("not captured: \(outcome)") }
        XCTAssertEqual(ClipBuilder.fileURLs(from: cap.reps[0].data).count, 5000)
        print("5000-file read took \(Date().timeIntervalSince(start))s")
        let item = try XCTUnwrap(ClipBuilder.build(cap, dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        XCTAssertEqual(item.preview, "file0.txt, file1.txt and 4998 more")
    }

    func testOversizedIsRejected() {
        let pb = NSPasteboard(name: .init("clipboard-history-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents(); pb.setString(String(repeating: "x", count: 2_000), forType: .string)
        guard case .tooLarge = PasteboardMonitor.read(expectedCount: pb.changeCount, maxBytes: 1_000, source: nil, pasteboard: pb)
        else { return XCTFail("expected tooLarge") }
    }

    func testKeyCodeForVOnCurrentLayout() {
        XCTAssertNotNil(PasteService.keyCode(for: "v"))
    }

    /// ⌘V must be sent on the key that means V for shortcuts in each layout (no system input-source change).
    func testKeyCodeForVOnOtherLayouts() throws {
        let expected: [(String, CGKeyCode)] = [
            ("com.apple.keylayout.US", 9), ("com.apple.keylayout.Dvorak", 47),
            ("com.apple.keylayout.DVORAK-QWERTYCMD", 9), ("com.apple.keylayout.French", 9),
            ("com.apple.keylayout.German", 9), ("com.apple.keylayout.Colemak", 9),
        ]
        for (id, code) in expected {
            let source = try XCTUnwrap(PasteService.layout(id: id), "\(id) not installed")
            XCTAssertEqual(PasteService.keyCode(for: "v", in: source), code, id)
        }
    }
}
