import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Turns raw pasteboard representations into a ClipItem and writes its blobs. Runs off the main thread.
enum ClipBuilder {
    static let previewLimit = 2_000
    static let searchLimit = 8_192   // ponytail: search sees the first 8 KB only; FTS5 if users need full-text over huge pastes

    static let plain = NSPasteboard.PasteboardType.string.rawValue   // public.utf8-plain-text
    static let rtf = NSPasteboard.PasteboardType.rtf.rawValue
    static let html = NSPasteboard.PasteboardType.html.rawValue
    static let png = NSPasteboard.PasteboardType.png.rawValue
    static let tiff = NSPasteboard.PasteboardType.tiff.rawValue
    static let jpeg = UTType.jpeg.identifier
    static let fileURL = NSPasteboard.PasteboardType.fileURLs.rawValue
    static let url = NSPasteboard.PasteboardType.urlType.rawValue
    static let color = NSPasteboard.PasteboardType.colorType.rawValue

    /// Types kept, in priority order. ponytail: app-private types (Pages, Figma) are dropped; store more if paste fidelity tests demand it.
    static let keptTypes = [fileURL, png, jpeg, tiff, color, url, rtf, html, plain]

    /// Builds the item and writes blobs into `dir`. Returns nil if nothing usable.
    static func build(_ capture: Capture, id: UUID = UUID(), dir: URL) throws -> ClipItem? {
        var reps = capture.reps.filter { !$0.data.isEmpty }
        guard !reps.isEmpty else { return nil }
        reps = normalizeImages(reps)

        let has = Set(reps.map(\.type))
        let text = reps.first { $0.type == plain }.flatMap { String(data: $0.data, encoding: .utf8) }
        let kind: ClipKind
        var preview: String
        var hashSource: Data

        if has.contains(fileURL), let rep = reps.first(where: { $0.type == fileURL }) {
            kind = .files
            let urls = fileURLs(from: rep.data)
            preview = fileListPreview(urls)
            hashSource = rep.data
        } else if let img = reps.first(where: { [png, jpeg].contains($0.type) }) {
            kind = .image
            preview = imagePreview(img)
            hashSource = img.data
        } else if has.contains(color), let rep = reps.first(where: { $0.type == color }) {
            kind = .color
            preview = colorHex(from: rep.data) ?? text ?? "Color"
            hashSource = rep.data
        } else if let t = text {
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if isHexColor(trimmed) { kind = .color }
            else if isWebURL(trimmed) { kind = .url }
            else if has.contains(rtf) || has.contains(html) { kind = .richText }
            else { kind = .text }
            preview = collapse(t)
            hashSource = Data(t.utf8)
        } else if let rep = reps.first(where: { $0.type == url }), let s = String(data: rep.data, encoding: .utf8) {
            kind = .url
            preview = s
            hashSource = rep.data
        } else if let rep = reps.first(where: { $0.type == rtf }),
                  let s = NSAttributedString(rtf: rep.data, documentAttributes: nil)?.string {
            kind = .richText
            preview = collapse(s)
            hashSource = Data(s.utf8)
        } else {
            return nil
        }
        if preview.isEmpty { preview = kind.label }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, rep) in reps.enumerated() {
            try rep.data.write(to: dir.appendingPathComponent("\(i)"), options: .atomic)
        }
        if kind == .image, let img = reps.first(where: { [png, jpeg].contains($0.type) }),
           let thumb = thumbnail(img.data, maxPixels: 128) {
            try thumb.write(to: dir.appendingPathComponent("thumb.png"), options: .atomic)
        }

        let search = fold(kind == .files ? preview : (text ?? preview))
        return ClipItem(id: id, createdAt: capture.date, lastUsedAt: capture.date, kind: kind,
                        preview: preview, searchText: search, sourceBundleID: capture.sourceBundleID,
                        pinned: false, byteSize: reps.reduce(0) { $0 + $1.data.count },
                        contentHash: SHA256.hash(data: hashSource).map { String(format: "%02x", $0) }.joined(),
                        types: reps.map(\.type))
    }

    // MARK: - Helpers

    /// Drops TIFF when PNG exists; converts TIFF-only images to PNG (TIFF is uncompressed and huge).
    static func normalizeImages(_ reps: [Representation]) -> [Representation] {
        guard let t = reps.firstIndex(where: { $0.type == tiff }) else { return reps }
        var out = reps
        if reps.contains(where: { [png, jpeg].contains($0.type) }) { out.remove(at: t); return out }
        if let pngData = convertToPNG(reps[t].data) { out[t] = Representation(type: png, data: pngData) }
        return out
    }

    static func convertToPNG(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    static func thumbnail(_ data: Data, maxPixels: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    static func imagePreview(_ rep: Representation) -> String {
        let format = rep.type == jpeg ? "JPEG" : "PNG"
        let size = ByteCountFormatter.string(fromByteCount: Int64(rep.data.count), countStyle: .file)
        guard let src = CGImageSourceCreateWithData(rep.data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return "Image · \(format) · \(size)" }
        return "\(w)×\(h) · \(format) · \(size)"
    }

    /// File URLs are stored newline-separated (one per pasteboard item).
    static func fileURLs(from data: Data) -> [URL] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { URL(string: String($0)) }
    }

    static func fileListPreview(_ urls: [URL]) -> String {
        let names = urls.map(\.lastPathComponent)
        switch names.count {
        case 0: return "Files"
        case 1...3: return names.joined(separator: ", ")
        default: return names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
        }
    }

    static func colorHex(from data: Data) -> String? {
        let color = (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data))
            ?? (NSUnarchiver.unarchiveObject(with: data) as? NSColor)
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    static func isHexColor(_ s: String) -> Bool {
        s.range(of: #"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"#, options: .regularExpression) != nil
    }

    static func isWebURL(_ s: String) -> Bool {
        guard !s.contains(where: \.isWhitespace), let u = URL(string: s), let scheme = u.scheme?.lowercased()
        else { return false }
        return ["http", "https"].contains(scheme) && u.host != nil
    }

    static func collapse(_ s: String) -> String {
        let head = s.prefix(previewLimit * 2)
        return head.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(previewLimit).description
    }

    static func fold(_ s: String) -> String {
        String(s.prefix(searchLimit)).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
