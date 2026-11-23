import AppKit
import os

private let log = Logger(subsystem: "app.clipboard-history", category: "monitor")

/// Polls NSPasteboard.changeCount (the only public change signal) with an adaptive interval.
@MainActor
final class PasteboardMonitor {
    enum Outcome: Sendable { case captured(Capture), tooLarge(Int), empty }

    var onCapture: (Capture) -> Void = { _ in }
    var onSkip: (String) -> Void = { _ in }
    var isPaused: () -> Bool = { false }
    var excludedApps: () -> Set<String> = { [] }
    var maxBytes: () -> Int = { 100_000_000 }

    private let pasteboard: NSPasteboard
    private var lastCount: Int
    private var ignoredCounts = Set<Int>()
    private var timer: DispatchSourceTimer?
    private var fastUntil = Date.distantPast
    private var currentInterval = 0.0

    static let fastInterval = 0.1, slowInterval = 0.5

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastCount = pasteboard.changeCount   // don't import whatever was on the clipboard before launch
    }

    func start() { schedule(Self.slowInterval) }
    func stop() { timer?.cancel(); timer = nil }

    /// Poll fast for a few seconds (after a copy or while the panel is open).
    func burst() { fastUntil = Date().addingTimeInterval(3); if currentInterval != Self.fastInterval { schedule(Self.fastInterval) } }

    /// Our own pasteboard writes must not become history items.
    func ignore(changeCount: Int) { ignoredCounts.insert(changeCount) }

    func poll() {
        let count = pasteboard.changeCount
        let wantFast = Date() < fastUntil
        if count != lastCount {
            lastCount = count
            if ignoredCounts.remove(count) == nil { handleChange(count) }
            burst()
        } else if !wantFast && currentInterval != Self.slowInterval {
            schedule(Self.slowInterval)
        }
    }

    private func schedule(_ interval: Double) {
        timer?.cancel()
        currentInterval = interval
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.poll() } }
        t.resume()
        timer = t
    }

    private func handleChange(_ count: Int) {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        let declaredSource = pasteboard.string(forType: .source)
        let source = declaredSource ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let verdict = PrivacyFilter.verdict(types: types, sourceBundleID: source,
                                            paused: isPaused(), excludedApps: excludedApps())
        guard verdict == .capture else {
            log.info("skipped change: \(String(describing: verdict), privacy: .public)")
            if verdict == .concealed { onSkip("Skipped a concealed item") }
            return
        }
        let limit = maxBytes()
        Task.detached(priority: .userInitiated) {
            let outcome = Self.read(expectedCount: count, maxBytes: limit, source: source)
            await MainActor.run { [weak self] in
                switch outcome {
                case .captured(let c): self?.onCapture(c)
                case .tooLarge(let n):
                    log.info("skipped oversized item: \(n, privacy: .public) bytes")
                    self?.onSkip("Item over \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) not saved")
                case .empty: break
                }
            }
        }
    }

    /// Reads the kept representations. Safe off the main thread; bails if the pasteboard changed mid-read.
    nonisolated static func read(expectedCount: Int, maxBytes: Int, source: String?,
                                 pasteboard: NSPasteboard = .general) -> Outcome {
        guard let items = pasteboard.pasteboardItems, let first = items.first else { return .empty }
        var reps: [Representation] = []
        var total = 0
        let fileURLs = items.compactMap { $0.string(forType: .fileURL) }
        if !fileURLs.isEmpty {
            let data = Data(fileURLs.joined(separator: "\n").utf8)
            reps.append(Representation(type: ClipBuilder.fileURL, data: data))
            total = data.count
        } else {
            let available = Set(first.types.map(\.rawValue))
            for type in ClipBuilder.keptTypes where available.contains(type) {
                guard let data = first.data(forType: .init(type)) else { continue }
                total += data.count
                if total > maxBytes { return .tooLarge(total) }
                reps.append(Representation(type: type, data: data))
            }
        }
        guard pasteboard.changeCount == expectedCount, !reps.isEmpty else { return .empty }
        return .captured(Capture(reps: reps, sourceBundleID: source))
    }
}
