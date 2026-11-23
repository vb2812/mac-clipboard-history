import AppKit
import SwiftUI
import Combine
import os

private let log = Logger(subsystem: "app.clipboard-history", category: "panel")
private let signposter = OSSignposter(subsystem: "app.clipboard-history", category: .pointsOfInterest)

/// Takes key status without activating Clipboard History, so the app being typed in stays frontmost.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: KeyPanel
    let model: PanelModel
    private var keyMonitor: Any?
    private var announceBag: AnyCancellable?
    private var flagsMonitor: Any?
    /// Hotkey-to-visible latencies in ms (most recent last), for perf measurement.
    private(set) var latencies: [Double] = []
    /// Time spent asking the frontmost app for its caret on the last show.
    private(set) var lastCaretMs: Double = 0
    private(set) var lastBreakdown = ""
    private(set) var lastShowAnimated = false

    static let size = NSSize(width: 360, height: 480)

    init(model: PanelModel) {
        self.model = model
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
                         backing: .buffered, defer: false)
        super.init()
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.minSize = NSSize(width: 320, height: 360)
        panel.setAccessibilityLabel("Clipboard History")
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: PanelView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        installMonitors()
        // Keyboard focus stays in the search field, so VoiceOver wouldn't notice ↑/↓ moving the selection
        // (found in the VoiceOver walkthrough). Announce the newly selected item instead.
        announceBag = model.cursor.$index.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.announceSelection() }
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// Lays out and draws once off-screen at launch so the first hotkey press is as fast as later ones.
    func warmUp() {
        model.reset()
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        model.isLive = false
        for item in model.store.items.prefix(20) { _ = IconCache.appIcon(item.sourceBundleID) }
    }

    func toggle() { isVisible ? hide() : show() }

    func clearLatencies() { latencies.removeAll() }

    func show() {
        let start = CACurrentMediaTime()
        let state = signposter.beginInterval("show")
        model.isLive = true
        model.reset()
        let tReset = CACurrentMediaTime()
        panel.sharingType = Prefs.d.bool(forKey: Prefs.hideFromCapture) ? .none : .readOnly
        let caretStart = CACurrentMediaTime()
        let caret = Self.caretRect()
        lastCaretMs = (CACurrentMediaTime() - caretStart) * 1000
        let tMove = CACurrentMediaTime()
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, caret: caret, mouse: NSEvent.mouseLocation))
        let tMoved = CACurrentMediaTime()
        var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLIPBOARD_HISTORY_REDUCE_MOTION"] != nil { reduceMotion = true }   // test without changing system settings
        #endif
        lastShowAnimated = !reduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        let tOrder = CACurrentMediaTime()
        panel.orderFrontRegardless()
        panel.makeKey()
        let tKey = CACurrentMediaTime()
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        // Measure until the window server has the frame: next runloop turn after display.
        panel.displayIfNeeded()
        let ms = (CACurrentMediaTime() - start) * 1000
        latencies.append(ms)
        if latencies.count > 200 { latencies.removeFirst() }
        signposter.endInterval("show", state)
        let f = { (a: CFTimeInterval, b: CFTimeInterval) in String(format: "%.1f", (b - a) * 1000) }
        lastBreakdown = "reset \(f(start, tReset)) caret \(f(caretStart, caretStart + lastCaretMs / 1000)) move \(f(tMove, tMoved)) pre-order \(f(tMoved, tOrder)) order+key \(f(tOrder, tKey)) display \(f(tKey, CACurrentMediaTime()))"
        log.info("panel shown in \(ms, format: .fixed(precision: 1), privacy: .public) ms (\(self.lastBreakdown, privacy: .public))")
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.isLive = false
        model.commandHeld = false
    }

    private func announceSelection() {
        guard panel.isVisible, NSWorkspace.shared.isVoiceOverEnabled else { return }
        let text: String
        if model.tab == .clipboard, let item = model.selected {
            text = "\(model.selection + 1) of \(model.count). " + ClipRow.spokenDescription(item)
        } else if model.glyphs.indices.contains(model.selection) {
            text = model.glyphs[model.selection].name
        } else { return }
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        lastAnnouncement = text
    }

    /// Last VoiceOver announcement (for tests).
    private(set) var lastAnnouncement = ""

    func windowDidResignKey(_ notification: Notification) {
        log.info("panel lost key → hiding; key window now: \(NSApp.keyWindow?.className ?? "none", privacy: .public), frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public)")
        hide()
    }

    // MARK: Positioning

    /// Caret bounds (Cocoa coordinates) of the focused text element, if Accessibility allows it.
    /// The AX query runs off the main thread and is abandoned after `budget`: Safari with a whole page
    /// selected blocked the main thread for 1.3 s answering it. Late answers are ignored (no jumping).
    static func caretRect(budget: TimeInterval = 0.025) -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let rect = withinBudget(budget, axCaretRect) else { return nil }
        // AX uses a top-left origin on the primary screen; convert to Cocoa bottom-left.
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Runs `work` on a background thread and returns its result only if it finishes within `budget`.
    nonisolated static func withinBudget<T: Sendable>(_ budget: TimeInterval, _ work: @escaping @Sendable () -> T?) -> T? {
        let box = BudgetBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async { box.value = work(); done.signal() }
        return done.wait(timeout: .now() + budget) == .success ? box.value : nil
    }

    nonisolated static func axCaretRect() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) != .success {
            // Electron/Chromium apps build their accessibility tree only after an assistive app asks for it
            // (seen with VS Code: focused-element query failed with -25204). Ask once; the next open finds the caret.
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.25)
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
                _ = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
            }
        }
        guard let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let el = element as! AXUIElement
        return insertionPointRect(el) ?? fieldAnchor(el)
    }

    /// Exact caret bounds, for apps that support AXBoundsForRange (Cocoa, WebKit).
    nonisolated private static func insertionPointRect(_ el: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let range = rangeRef, CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        // Use only the insertion point: bounds for a huge selection is what made Safari slow.
        var cf = CFRange()
        guard AXValueGetValue(range as! AXValue, .cfRange, &cf) else { return nil }
        var caret = CFRange(location: cf.location + cf.length, length: 0)
        guard let caretRange = AXValueCreate(.cfRange, &caret) else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         caretRange, &boundsRef) == .success,
              let b = boundsRef, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &rect), rect.height > 0, rect.height < 400 else { return nil }
        return rect
    }

    /// Fallback for apps without caret bounds (Electron/Chromium, some cross-platform toolkits, C-06):
    /// anchor at the top-left of the focused text field so the panel still opens where the user is typing.
    nonisolated private static func fieldAnchor(_ el: AXUIElement) -> CGRect? {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let z = sizeRef else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(z as! AXValue, .cgSize, &size) else { return nil }
        return fieldAnchorRect(role: roleRef as? String, frame: CGRect(origin: origin, size: size))
    }

    /// Pure part of the fallback (unit-tested): text roles only, and only frames that look like a field or editor.
    nonisolated static func fieldAnchorRect(role: String?, frame: CGRect) -> CGRect? {
        let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField", "AXWebArea"]
        guard let role, textRoles.contains(role) else { return nil }
        // VS Code/Electron put a zero-width hidden <textarea> exactly at the caret: that frame *is* the caret.
        if frame.width < 20 { return (8...60).contains(frame.height) ? CGRect(x: frame.minX, y: frame.minY, width: 1, height: frame.height) : nil }
        guard frame.height >= 12 else { return nil }
        // Single-line fields: anchor at the field itself. Editors: a line-high rect at the top-left inset.
        let height = min(frame.height, 20)
        return CGRect(x: frame.minX + 8, y: frame.minY + (frame.height > 40 ? 8 : 0), width: 1, height: height)
    }


    /// Panel origin: below the caret (or at the mouse), clamped to the visible frame of that screen. Pure for tests.
    static func origin(for size: NSSize, caret: NSRect?, mouse: NSPoint,
                       screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> NSPoint {
        let anchor = caret.map { NSPoint(x: $0.minX, y: $0.minY - 4) } ?? mouse
        let probe = caret.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouse
        let frame = screens.first { $0.insetBy(dx: -1, dy: -1).contains(probe) } ?? screens.first ?? .zero
        let margin: CGFloat = 8
        var x = anchor.x
        var y = anchor.y - size.height       // top-left at the anchor, growing down
        if y < frame.minY + margin, let c = caret { y = c.maxY + 4 }   // flip above the caret
        x = min(max(x, frame.minX + margin), frame.maxX - size.width - margin)
        y = min(max(y, frame.minY + margin), frame.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }

    // MARK: Keyboard

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isPanel = event.window === self?.panel
            guard isPanel, let key = MainActor.assumeIsolated({ Self.key(for: event) }) else { return event }
            let handled = MainActor.assumeIsolated { self?.model.handle(key) ?? false }
            return handled ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            if event.window === self?.panel { MainActor.assumeIsolated { self?.model.commandHeld = held } }
            return event
        }
    }

    static func key(for event: NSEvent) -> PanelModel.Key? {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 36, 76: return mods.contains(.shift) ? .shiftEnter : .enter
        case 53: return .escape
        case 48: return mods.contains(.shift) ? .backTab : .tab
        case 51: return mods == .command ? .commandDelete : (mods.isEmpty ? .delete : nil)
        default: break
        }
        guard mods == .command, let chars = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        if chars == "p" { return .pin }
        if chars == "y" { return .preview }
        if chars == "," { return .settings }
        if let n = Int(chars), (1...9).contains(n) { return .quick(n) }
        return nil
    }
}

/// Small HUD shown when auto-paste isn't possible. Plain AppKit so its size is known before it is shown
/// (the SwiftUI version measured as an empty capsule; found in the Accessibility-off check).
@MainActor
final class Toast {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, near point: NSPoint) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.textColor = .labelColor
        let size = label.intrinsicContentSize
        let frameSize = NSSize(width: ceil(size.width) + 28, height: ceil(size.height) + 16)
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: frameSize))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = frameSize.height / 2
        effect.layer?.masksToBounds = true
        label.frame = NSRect(x: 14, y: 8, width: ceil(size.width), height: ceil(size.height))
        effect.addSubview(label)

        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.ignoresMouseEvents = true
            return p
        }()
        panel = p
        p.contentView = effect
        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = min(max(point.x - frameSize.width / 2, screen.minX + 8), screen.maxX - frameSize.width - 8)
        let y = min(max(point.y - frameSize.height - 12, screen.minY + 8), screen.maxY - frameSize.height - 8)
        p.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: frameSize), display: true)
        p.orderFrontRegardless()
        NSAccessibility.post(element: p, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        hideTask?.cancel()
        hideTask = Task { [weak p] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { p?.orderOut(nil) }
        }
    }
}

/// Result slot for `PanelController.withinBudget`; written once on the worker before it signals.
private final class BudgetBox<T>: @unchecked Sendable { var value: T? }
