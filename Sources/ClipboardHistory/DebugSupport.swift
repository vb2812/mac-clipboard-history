#if DEBUG
import AppKit
import SwiftUI
import KeyboardShortcuts
import ServiceManagement

/// Test automation hooks (Debug builds only): `osascript` posts a distributed notification
/// named app.clipboard-history.debug with a command string as the object.
@MainActor
enum DebugHooks {
    static func install(_ app: AppDelegate) {
        DistributedNotificationCenter.default().addObserver(forName: .init("app.clipboard-history.debug"), object: nil, queue: .main) { [weak app] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                guard let app else { return }
                handle(command, app: app)
            }
        }
    }

    static func handle(_ command: String, app: AppDelegate) {
        switch command {
        case "toggle": app.togglePanel()
        case "hide": app.panel.hide()
        case "settings": app.showSettings()
        case "onboarding": app.showOnboarding()
        case "dump": dump(app)
        case "quit": NSApp.terminate(nil)
        case "login:on": try? SMAppService.mainApp.register(); dump(app)
        case "login:off": try? SMAppService.mainApp.unregister(); dump(app)
        case let c where c.hasPrefix("key:"):   // e.g. key:down, key:enter, key:shiftEnter, key:quick3
            let name = String(c.dropFirst(4))
            let key: PanelModel.Key? = switch name {
            case "up": .up; case "down": .down; case "enter": .enter; case "shiftEnter": .shiftEnter
            case "escape": .escape; case "tab": .tab; case "delete": .delete; case "pin": .pin
            case "commandDelete": .commandDelete; case "preview": .preview
            default: name.hasPrefix("quick") ? Int(name.dropFirst(5)).map { .quick($0) } : nil
            }
            if let key { _ = app.panel.model.handle(key) }
        case let c where c.hasPrefix("query:"): app.panel.model.query = String(c.dropFirst(6))
        case let c where c.hasPrefix("shortcut:"):   // shortcut:<carbonKeyCode>:<carbonModifiers> | shortcut:none | shortcut:reset
            let parts = c.split(separator: ":")
            if parts.count == 3, let k = Int(parts[1]), let m = Int(parts[2]) {
                KeyboardShortcuts.setShortcut(.init(carbonKeyCode: k, carbonModifiers: m), for: .openPanel)
            } else if parts.last == "none" { KeyboardShortcuts.setShortcut(nil, for: .openPanel) }
            else { KeyboardShortcuts.reset(.openPanel) }
        case "clearlatency": app.panel.clearLatencies()
        default: break
        }
    }

    /// Writes state for test scripts to $CLIPBOARD_HISTORY_DATA_DIR/debug-state.json (or the support dir).
    static func dump(_ app: AppDelegate) {
        let lat = app.panel.latencies
        let state: [String: Any] = [
            "count": app.store.items.count,
            "pinned": app.store.items.filter(\.pinned).count,
            "kinds": app.store.items.map(\.kind.rawValue),
            "previews": app.store.items.prefix(10).map { String($0.preview.prefix(80)) },
            "panelVisible": app.panel.isVisible,
            "panelKey": app.panel.panel.isKeyWindow,
            "panelWindowNumber": app.panel.panel.windowNumber,
            "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
            "appActive": NSApp.isActive,
            "latenciesMs": lat,
            "lastCaretMs": app.panel.lastCaretMs,
            "lastBreakdown": app.panel.lastBreakdown,
            "lastShowAnimated": app.panel.lastShowAnimated,
            "lastAnnouncement": app.panel.lastAnnouncement,
            "panelAlpha": app.panel.panel.alphaValue,
            "loginItem": "\(SMAppService.mainApp.status.rawValue)",
            "axTrusted": AXIsProcessTrusted(),
            "keyWindowTitle": NSApp.keyWindow?.title ?? "",
            "selection": app.panel.model.selection,
            "query": app.panel.model.query,
            "tab": app.panel.model.tab.rawValue,
            "clipboardAccess": "\(Permissions.clipboard)",
            "residentMB": residentMB(),
            "hotkeyEnabled": KeyboardShortcuts.isEnabled(for: .openPanel),
            "hotkey": KeyboardShortcuts.getShortcut(for: .openPanel)?.description ?? "none",
        ]
        let url = AppDelegate.supportDirectory.appendingPathComponent("debug-state.json")
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}

/// Renders every DESIGN.md state to PNGs with `screencapture -l` (needs the launching shell to have Screen Recording).
@MainActor
enum StateRenderer {
    static func run(outputDir: URL) {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-history-render-\(UUID().uuidString)")
        let store = ClipStore(root: tmp, limit: 100)
        let model = PanelModel(store: store)
        let controller = PanelController(model: model)
        Task { @MainActor in
            @MainActor func shot(_ name: String, dark: Bool = false, contrast: Bool = false, _ setup: @MainActor () -> Void) async {
                let look: NSAppearance.Name = contrast ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                                                       : (dark ? .darkAqua : .aqua)
                NSApp.appearance = NSAppearance(named: look)
                controller.hide()
                Prefs.d.set(false, forKey: Prefs.hideFromCapture)
                controller.show()
                model.banner = nil; model.notice = nil
                setup()
                try? await Task.sleep(for: .milliseconds(450))
                capture(controller.panel, to: outputDir.appendingPathComponent("\(name).png"))
            }
            await shot("01-empty") {}
            seed(store)
            await shot("02-list-light") {}
            await shot("03-list-dark", dark: true) {}
            await shot("04-cmd-held") { model.commandHeld = true }
            await shot("05-search") { model.query = "npm" }
            await shot("06-no-results") { model.query = "zzzz" }
            await shot("07-paused") { model.banner = .paused }
            await shot("08-no-clipboard-access") { model.banner = .noClipboardAccess }
            await shot("09-db-recovered") { model.banner = .recovered }
            await shot("10-confirm-clear") { model.confirmingClear = true }
            await shot("11-concealed-skipped") { model.flash("Skipped a concealed item") }
            await shot("12-too-large") { model.flash("Item over 100 MB not saved") }
            await shot("13-emoji") { model.tab = .emoji }
            await shot("14-emoji-search") { model.tab = .emoji; model.query = "heart" }
            await shot("15-symbols", dark: true) { model.tab = .symbols }
            await shot("16-kaomoji") { model.tab = .kaomoji }
            await shot("17-selected-row-3") { model.selection = 3 }
            await shot("18-preview-text") { model.selection = 3; model.previewing = true }
            await shot("19-preview-image", dark: true) { model.selection = 5; model.previewing = true }
            await shot("19b-preview-color") { model.selection = 6; model.previewing = true }
            await shot("19c-preview-files") { model.selection = 7; model.previewing = true }
            await shot("22-high-contrast-light", contrast: true) {}
            await shot("23-high-contrast-dark", dark: true, contrast: true) {}
            controller.hide()
            // Settings and onboarding windows.
            for (name, view) in [("20-settings", AnyView(SettingsView(store: store))), ("21-onboarding", AnyView(OnboardingView {}))] {
                let w = NSWindow(contentViewController: NSHostingController(rootView: view))
                w.styleMask = [.titled, .closable]
                w.title = name.hasSuffix("settings") ? "Clipboard History Settings" : "Welcome to Clipboard History"
                w.center(); w.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(600))
                capture(w, to: outputDir.appendingPathComponent("\(name).png"))
                w.orderOut(nil)
            }
            try? FileManager.default.removeItem(at: tmp)
            Prefs.d.removeObject(forKey: Prefs.hideFromCapture)
            NSApp.terminate(nil)
        }
    }

    static func capture(_ window: NSWindow, to url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", url.path]
        try? p.run(); p.waitUntilExit()
    }

    static func seed(_ store: ClipStore) {
        func add(_ reps: [Representation], source: String?, ago: TimeInterval, pin: Bool = false) {
            let id = UUID()
            guard var item = try? ClipBuilder.build(Capture(reps: reps, sourceBundleID: source, date: Date().addingTimeInterval(-ago)),
                                                    id: id, dir: store.blobDir(id)) else { return }
            item.pinned = false
            store.insert(item)
            if pin { store.togglePin(item.id) }
        }
        func text(_ s: String) -> Representation { Representation(type: ClipBuilder.plain, data: Data(s.utf8)) }
        let img = NSImage(size: NSSize(width: 800, height: 500), flipped: false) { r in
            NSGradient(colors: [.systemPink, .systemOrange])!.draw(in: r, angle: 30); return true
        }
        let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        add([text("ssh deploy@prod-01.internal -p 2222")], source: "com.apple.Terminal", ago: 86_400, pin: true)
        add([text("Best regards,\nAlex")], source: "com.apple.mail", ago: 50_000, pin: true)
        add([Representation(type: ClipBuilder.fileURL, data: Data("file:///Applications/Safari.app\nfile:///System/Library/CoreServices/Finder.app\nfile:///Applications/Utilities/Terminal.app\nfile:///Applications/Notes.app".utf8))],
            source: "com.apple.finder", ago: 7200)
        add([text("#FF6A00")], source: "com.figma.Desktop", ago: 3600)
        add([Representation(type: ClipBuilder.png, data: png)], source: "com.apple.Preview", ago: 900)
        add([text("https://developer.apple.com/documentation/appkit/nspanel")], source: "com.apple.Safari", ago: 300)
        add([text(String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 40))], source: "com.apple.TextEdit", ago: 120)
        add([text("npm run build && npm test"), Representation(type: ClipBuilder.rtf, data: Data("{\\rtf1 npm run build}".utf8))],
            source: "com.microsoft.VSCode", ago: 5)
    }
}
#endif
