import AppKit
import os

private let log = Logger(subsystem: "app.clipboard-history", category: "store")

/// History metadata in SQLite, representations as files in blobs/<uuid>/<index>.
@MainActor
final class ClipStore: ObservableObject {
    /// Most recently used first.
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var recoveredFromCorruption = false

    let root: URL
    var blobsRoot: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    var limit: Int
    private var db: Database!

    static let schemaVersion = 1

    init(root: URL, limit: Int = 25) {
        self.root = root
        self.limit = limit
        try? FileManager.default.createDirectory(at: blobsRoot, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("history.sqlite").path
        do {
            db = try Database(path: path)
            guard db.isIntact else { throw Database.Failure.open("integrity check failed") }
            try migrate()
            try load()
        } catch {
            log.error("history unreadable, starting fresh: \(String(describing: error), privacy: .public)")
            quarantine(path)
            db = try! Database(path: path)   // fresh file in our own folder; failure here is unrecoverable
            try! migrate()
            recoveredFromCorruption = true
        }
        if !recoveredFromCorruption { removeOrphanBlobs() }
    }

    func blobDir(_ id: UUID) -> URL { blobsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    func thumbnailURL(_ item: ClipItem) -> URL { blobDir(item.id).appendingPathComponent("thumb.png") }

    // MARK: - Mutations

    /// Inserts a built item; an identical item (same hash) moves to the top instead.
    func insert(_ item: ClipItem) {
        if let i = items.firstIndex(where: { $0.contentHash == item.contentHash && $0.kind == item.kind }) {
            let dupDir = blobDir(item.id)
            Task.detached { try? FileManager.default.removeItem(at: dupDir) }
            var existing = items.remove(at: i)
            existing.lastUsedAt = item.createdAt
            existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
            items.insert(existing, at: 0)
            persist { try $0.run("UPDATE items SET used=?, source=? WHERE id=?",
                                 [existing.lastUsedAt.timeIntervalSince1970, existing.sourceBundleID, existing.id.uuidString]) }
            return
        }
        items.insert(item, at: 0)
        persist { db in
            try db.run("INSERT INTO items VALUES (?,?,?,?,?,?,?,?,?,?,?)", [
                item.id.uuidString, item.createdAt.timeIntervalSince1970, item.lastUsedAt.timeIntervalSince1970,
                item.kind.rawValue, item.preview, item.searchText, item.sourceBundleID, item.pinned,
                item.byteSize, item.contentHash, item.types.joined(separator: "\n"),
            ])
        }
        evict()
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        let pinned = items[i].pinned
        persist { try $0.run("UPDATE items SET pinned=? WHERE id=?", [pinned, id.uuidString]) }
        evict()
    }

    func delete(_ id: UUID) { remove(items.filter { $0.id == id }) }

    /// Windows "Clear all": keeps pinned items.
    func clearUnpinned() { remove(items.filter { !$0.pinned }) }

    func clearEverything() { remove(items) }

    /// Removes unpinned items last used before `date` (Settings → "Remove unpinned items after").
    func expire(before date: Date) { remove(items.filter { !$0.pinned && $0.lastUsedAt < date }) }

    /// Re-applies the limit (e.g. after the user lowers it).
    func evict() {
        let unpinned = items.filter { !$0.pinned }
        guard unpinned.count > limit else { return }
        remove(Array(unpinned.suffix(unpinned.count - limit)))
    }

    // MARK: - Reading blobs

    func representations(of item: ClipItem) -> [Representation] {
        let dir = blobDir(item.id)
        return item.types.enumerated().compactMap { i, type in
            (try? Data(contentsOf: dir.appendingPathComponent("\(i)"), options: .mappedIfSafe))
                .map { Representation(type: type, data: $0) }
        }
    }

    /// Plain-text form used by "paste as plain text".
    func plainText(of item: ClipItem) -> String? {
        let reps = representations(of: item)
        func data(_ t: String) -> Data? { reps.first { $0.type == t }?.data }
        if let d = data(ClipBuilder.plain), let s = String(data: d, encoding: .utf8) { return s }
        if let d = data(ClipBuilder.rtf), let a = NSAttributedString(rtf: d, documentAttributes: nil) { return a.string }
        if let d = data(ClipBuilder.url), let s = String(data: d, encoding: .utf8) { return s }
        if let d = data(ClipBuilder.fileURL) { return ClipBuilder.fileURLs(from: d).map(\.path).joined(separator: "\n") }
        if item.kind == .color { return item.preview }
        return nil
    }

    // MARK: - Private

    private func remove(_ victims: [ClipItem]) {
        guard !victims.isEmpty else { return }
        let ids = Set(victims.map(\.id))
        items.removeAll { ids.contains($0.id) }
        persist { db in
            try db.exec("BEGIN")
            for id in ids { try db.run("DELETE FROM items WHERE id=?", [id.uuidString]) }
            try db.exec("COMMIT")
        }
        let dirs = ids.map(blobDir)
        Task.detached(priority: .utility) { for d in dirs { try? FileManager.default.removeItem(at: d) } }
    }

    private func persist(_ body: (Database) throws -> Void) {
        do { try body(db) } catch {
            try? db.exec("ROLLBACK")
            log.error("db write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func migrate() throws {
        if db.userVersion < 1 {
            try db.exec("""
            CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY, created REAL NOT NULL, used REAL NOT NULL,
              kind TEXT NOT NULL, preview TEXT NOT NULL, search TEXT NOT NULL, source TEXT, pinned INTEGER NOT NULL,
              size INTEGER NOT NULL, hash TEXT NOT NULL, types TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS items_used ON items(used DESC);
            """)
            db.userVersion = 1
        }
        // Future: if db.userVersion < 2 { ALTER TABLE …; db.userVersion = 2 }
    }

    private func load() throws {
        items = try db.run("SELECT id,created,used,kind,preview,search,source,pinned,size,hash,types FROM items ORDER BY used DESC")
            .compactMap { r in
                guard let id = (r[0] as? String).flatMap(UUID.init(uuidString:)),
                      let kind = (r[3] as? String).flatMap(ClipKind.init(rawValue:)) else { return nil }
                return ClipItem(id: id, createdAt: Date(timeIntervalSince1970: r[1] as? Double ?? 0),
                                lastUsedAt: Date(timeIntervalSince1970: r[2] as? Double ?? 0), kind: kind,
                                preview: r[4] as? String ?? "", searchText: r[5] as? String ?? "",
                                sourceBundleID: r[6] as? String, pinned: (r[7] as? Int ?? 0) != 0,
                                byteSize: r[8] as? Int ?? 0, contentHash: r[9] as? String ?? "",
                                types: (r[10] as? String ?? "").split(separator: "\n").map(String.init))
            }
    }

    private func quarantine(_ path: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            try? FileManager.default.moveItem(atPath: path + suffix, toPath: path + ".corrupt-\(stamp)" + suffix)
        }
    }

    /// Deletes blob folders with no DB row (left by a crash between blob write and insert).
    /// Only folders created before launch: anything newer may belong to a capture still in flight.
    private func removeOrphanBlobs() {
        let known = Set(items.map(\.id.uuidString))
        let root = blobsRoot
        let launch = Date()
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let dirs = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            for d in dirs where !known.contains(d) {
                let url = root.appendingPathComponent(d)
                let created = (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? launch
                if created < launch { try? fm.removeItem(at: url) }
            }
        }
    }
}
