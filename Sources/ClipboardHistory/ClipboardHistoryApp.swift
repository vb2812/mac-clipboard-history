import AppKit
import Carbon.HIToolbox
import SwiftUI
import KeyboardShortcuts
import os

private let log = Logger(subsystem: "app.clipboard-history", category: "app")

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private(set) var store: ClipStore!
    private(set) var panel: PanelController!
    private var monitor: PasteboardMonitor!
    private let toast = Toast()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    static func main() {
        umask(0o077)   // history, blobs and DB are private to the user
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLIPBOARD_HISTORY_DATA_DIR"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipboard History", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }   // unit-test host: stay inert
        Prefs.registerDefaults()
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--render-states"), i + 1 < CommandLine.arguments.count {
            StateRenderer.run(outputDir: URL(fileURLWithPath: CommandLine.arguments[i + 1])); return
        }
        #endif
        store = ClipStore(root: Self.supportDirectory, limit: Prefs.d.integer(forKey: Prefs.historyLimit))
        let model = PanelModel(store: store)
        panel = PanelController(model: model)
        model.onPaste = { [weak self] item, plain in self?.paste(item, plain: plain) }
        model.onInsertText = { [weak self] text in self?.pasteText(text) }
        model.onCopyText = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            model.flash("Copied \(text)")
        }
        model.onClose = { [weak self] in self?.panel.hide() }
        model.onResume = { Prefs.d.set(false, forKey: Prefs.paused) }
        model.onOpenPrivacySettings = { Permissions.openClipboardSettings() }
        model.onOpenSettings = { [weak self] in self?.showSettings() }

        monitor = PasteboardMonitor()
        monitor.isPaused = { Prefs.d.bool(forKey: Prefs.paused) }
        monitor.excludedApps = { Set(Prefs.d.stringArray(forKey: Prefs.excludedApps) ?? []) }
        monitor.maxBytes = { Prefs.d.integer(forKey: Prefs.maxItemMB) * 1_000_000 }
        monitor.onCapture = { [weak self] capture in self?.ingest(capture) }
        monitor.onSkip = { [weak self] message in self?.panel.model.flash(message) }
        monitor.start()

        KeyboardShortcuts.onKeyDown(for: .openPanel) { [weak self] in
            MainActor.assumeIsolated { self?.togglePanel() }
        }
        setUpStatusItem()
        expireOldItems()
        panel.warmUp()
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if Prefs.d.bool(forKey: Prefs.clearOnLock) { self?.store.clearUnpinned(); log.info("cleared unpinned history on screen lock") }
            }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshState() }
        }
        refreshState()
        #if DEBUG
        // Test automation only: any local process can post distributed notifications, so the hooks stay off
        // unless a test run opts in (isolated data dir or explicit flag). Release builds don't contain them.
        let env = ProcessInfo.processInfo.environment
        if env["CLIPBOARD_HISTORY_DATA_DIR"] != nil || env["CLIPBOARD_HISTORY_DEBUG_HOOKS"] != nil { DebugHooks.install(self) }
        #endif
        if !Prefs.d.bool(forKey: Prefs.onboarded) && ProcessInfo.processInfo.environment["CLIPBOARD_HISTORY_SKIP_ONBOARDING"] == nil {
            showOnboarding()
        }
    }

    /// Opening Clipboard History again (Finder, Spotlight, Launchpad) shows Settings: the way in when the
    /// menu bar icon is hidden behind the notch or turned off in System Settings → Menu Bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if store != nil { showSettings() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if store != nil, Prefs.d.bool(forKey: Prefs.clearOnQuit) { store.clearUnpinned() }
    }

    // MARK: Core loop

    private func ingest(_ capture: Capture) {
        let id = UUID()
        let dir = store.blobDir(id)
        Task.detached(priority: .userInitiated) {
            let item: ClipItem?
            do { item = try ClipBuilder.build(capture, id: id, dir: dir) } catch {
                log.error("could not save item: \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: dir)
                await MainActor.run { [weak self] in self?.panel.model.flash("Couldn't save the copied item (disk full?)") }
                return
            }
            guard let item else { return }
            await MainActor.run { [weak self] in
                self?.store.insert(item)
                self?.expireOldItems()
                log.info("captured \(item.kind.rawValue, privacy: .public) \(item.byteSize, privacy: .public) bytes from \(item.sourceBundleID ?? "?", privacy: .public)")
            }
        }
    }

    func togglePanel() {
        if panel.isVisible { panel.hide(); return }
        refreshState()
        expireOldItems()
        monitor.poll()   // pick up a copy made in the last few hundred ms
        panel.show()
        monitor.burst()
    }

    private func paste(_ item: ClipItem, plain: Bool) {
        let reps = store.representations(of: item)
        let text = store.plainText(of: item)
        guard !reps.isEmpty || text != nil else { panel.model.flash("This item's data is missing"); return }
        // No reordering on paste (Win+V parity): ⌘1–9 positions must not shift between pastes.
        monitor.ignore(changeCount: PasteService.write(reps, plainText: text, asPlain: plain))
        finishPaste()
    }

    private func pasteText(_ text: String) {
        monitor.ignore(changeCount: PasteService.write([], plainText: text, asPlain: true))
        finishPaste()
    }

    /// Closes the panel and sends ⌘V to the app that was frontmost all along, or tells the user to press it.
    private func finishPaste() {
        let anchor = NSPoint(x: panel.panel.frame.midX, y: panel.panel.frame.maxY - 40)
        panel.hide()
        guard PasteService.canAutoPaste else {
            let reason = IsSecureEventInputEnabled() ? "Copied — press ⌘V (a password field blocks auto-paste)" : "Copied — press ⌘V to paste"
            toast.show(reason, near: anchor)
            return
        }
        // Let the panel give up key status before the synthetic keystroke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { PasteService.postCommandV() }
    }

    // MARK: State

    private func expireOldItems() {
        let hours = Prefs.d.integer(forKey: Prefs.expireHours)
        if hours > 0 { store.expire(before: Date().addingTimeInterval(-Double(hours) * 3600)) }
    }

    private func refreshState() {
        guard store != nil else { return }
        let paused = Prefs.d.bool(forKey: Prefs.paused)
        let access = Permissions.clipboard
        panel.model.banner = paused ? .paused : (access == .denied ? .noClipboardAccess : (store.recoveredFromCorruption ? .recovered : nil))
        store.limit = Prefs.d.integer(forKey: Prefs.historyLimit)
        statusItem?.button?.image = NSImage(systemSymbolName: paused ? "pause.circle" : "list.clipboard",
                                            accessibilityDescription: paused ? "Clipboard History (paused)" : "Clipboard History")
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = menu.addItem(withTitle: "Open Clipboard", action: #selector(openFromMenu), keyEquivalent: "")
        open.setShortcut(for: .openPanel)
        let paused = Prefs.d.bool(forKey: Prefs.paused)
        menu.addItem(withTitle: paused ? "Resume Recording" : "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(withTitle: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        if Permissions.clipboard == .denied {
            menu.addItem(withTitle: "Clipboard Access Is Off — Open Settings…", action: #selector(openClipboardSettings), keyEquivalent: "")
        }
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "Turn On Auto-Paste…", action: #selector(enableAutoPaste), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Welcome Guide…", action: #selector(showOnboardingFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clipboard History", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc private func openFromMenu() {
        // Let the menu finish closing so the panel can take key status.
        DispatchQueue.main.async { self.togglePanel() }
    }
    @objc private func togglePause() { Prefs.d.set(!Prefs.d.bool(forKey: Prefs.paused), forKey: Prefs.paused) }
    @objc private func openClipboardSettings() { Permissions.openClipboardSettings() }
    @objc private func enableAutoPaste() { PasteService.requestAccessibility(); Permissions.openAccessibilitySettings() }
    @objc private func showOnboardingFromMenu() { showOnboarding() }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned items are kept unless you choose Clear Everything."
        alert.addButton(withTitle: "Clear Unpinned")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Clear Everything")
        switch alert.runModal() {
        case .alertFirstButtonReturn: store.clearUnpinned()
        case .alertThirdButtonReturn: store.clearEverything()
        default: break
        }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            w.title = "Clipboard History Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        Self.centerOnActiveScreen(settingsWindow)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        Self.dropInitialFocus(settingsWindow)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView { [weak self] in
                Prefs.d.set(true, forKey: Prefs.onboarded)
                self?.onboardingWindow?.close()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Welcome to Clipboard History"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            onboardingWindow = w
        }
        Self.centerOnActiveScreen(onboardingWindow)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        Self.dropInitialFocus(onboardingWindow)
    }

    /// `NSWindow.center()` ran before SwiftUI sized the content, so windows opened off-center.
    /// Size to fit first, then center on the screen with the mouse.
    static func centerOnActiveScreen(_ window: NSWindow?) {
        guard let window, let content = window.contentViewController?.view else { return }
        window.setContentSize(content.fittingSize)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { window.center(); return }
        window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2 + frame.height / 8))
    }

    /// AppKit gives the first key view (the shortcut recorder) focus when a window opens, so the next
    /// key combo the user presses silently becomes the new shortcut. Only record after an explicit click.
    static func dropInitialFocus(_ window: NSWindow?) {
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }
    }
}
