import SwiftUI
import KeyboardShortcuts
import ServiceManagement
import UniformTypeIdentifiers

enum Permissions {
    enum ClipboardAccess { case allowed, ask, denied, notApplicable }

    static var clipboard: ClipboardAccess {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return .allowed
            case .alwaysDeny: return .denied
            case .ask, .default: return .ask
            @unknown default: return .ask
            }
        }
        return .notApplicable
    }

    static func openClipboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard")!)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// Shortcut recorder with our conflict rules, reset and clear.
struct ShortcutField: View {
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                KeyboardShortcuts.Recorder(for: .openPanel) { new in
                    warning = new.flatMap { if case .warn(let w) = ShortcutRules.check($0) { w } else { nil } }
                }
                .shortcutValidation { s in
                    if case .block(let reason) = ShortcutRules.check(s) { return .disallow(reason: reason) }
                    return .allow
                }
                Button("Reset to Default") {
                    KeyboardShortcuts.reset(.openPanel)
                    warning = KeyboardShortcuts.getShortcut(for: .openPanel).flatMap {
                        if case .warn(let w) = ShortcutRules.check($0) { w } else { nil }
                    }
                }
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
            if KeyboardShortcuts.getShortcut(for: .openPanel) == nil {
                Text("No shortcut — open Clipboard History from the menu bar.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            warning = KeyboardShortcuts.getShortcut(for: .openPanel).flatMap {
                if case .warn(let w) = ShortcutRules.check($0) { w } else { nil }
            }
        }
    }
}

struct SettingsView: View {
    let store: ClipStore
    var body: some View {
        TabView {
            GeneralPane(store: store).tabItem { Label("General", systemImage: "gearshape") }
            Form { Section("Open Clipboard History") { ShortcutField() } }.formStyle(.grouped)
                .tabItem { Label("Shortcut", systemImage: "command") }
            PrivacyPane().tabItem { Label("Privacy", systemImage: "hand.raised") }
            AppearancePane().tabItem { Label("Appearance", systemImage: "paintbrush") }
            AboutPane().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 400)
    }
}

private struct GeneralPane: View {
    let store: ClipStore
    @AppStorage(Prefs.historyLimit) private var limit = 25
    @AppStorage(Prefs.maxItemMB) private var maxMB = 100
    @AppStorage(Prefs.clearOnQuit) private var clearOnQuit = false
    @AppStorage(Prefs.expireHours) private var expireHours = 0
    @AppStorage(Prefs.plainByDefault) private var plainByDefault = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("History") {
                Picker("Keep", selection: $limit) {
                    ForEach([10, 25, 50, 100, 250, 500, 1000, 2500, 5000], id: \.self) { Text("\($0) items").tag($0) }
                }
                .onChange(of: limit) { store.limit = limit; store.evict() }
                Text("Pinned items don't count toward the limit.").font(.caption).foregroundStyle(.secondary)
                Picker("Largest item", selection: $maxMB) {
                    ForEach([5, 25, 100, 250], id: \.self) { Text("\($0) MB").tag($0) }
                }
                Picker("Remove unpinned items after", selection: $expireHours) {
                    Text("Never").tag(0); Text("1 hour").tag(1); Text("1 day").tag(24)
                    Text("1 week").tag(168); Text("30 days").tag(720)
                }
                Toggle("Clear unpinned history when Clipboard History quits", isOn: $clearOnQuit)
            }
            Section("Pasting") {
                Toggle("Paste as plain text by default (⇧Return keeps formatting)", isOn: $plainByDefault)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacyPane: View {
    @AppStorage(Prefs.paused) private var paused = false
    @AppStorage(Prefs.hideFromCapture) private var hideFromCapture = true
    @AppStorage(Prefs.clearOnLock) private var clearOnLock = false
    @State private var apps: [String] = Prefs.d.stringArray(forKey: Prefs.excludedApps) ?? []
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                Toggle("Pause recording", isOn: $paused)
                Toggle("Hide the pop-up in screen recordings and screen sharing", isOn: $hideFromCapture)
                Toggle("Clear unpinned history when the screen locks", isOn: $clearOnLock)
            } footer: {
                Text("Clipboard History never uses the network. Items marked as passwords by password managers are never saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ignore copies from these apps") {
                List(selection: $selection) {
                    ForEach(apps, id: \.self) { id in
                        HStack {
                            if let icon = IconCache.appIcon(id) { Image(nsImage: icon) }
                            else { Image(systemName: "app.dashed").frame(width: 20).foregroundStyle(.secondary) }
                            Text(IconCache.appName(id) ?? PrivacyFilter.knownNames[id] ?? id)
                            Spacer()
                            Text(id).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(minHeight: 110)
                HStack {
                    Button("Add App…", action: addApp)
                    Button("Remove") { apps.removeAll { $0 == selection }; save() }.disabled(selection == nil)
                    Spacer()
                    Button("Restore Defaults") { apps = PrivacyFilter.defaultExcludedApps; save() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !apps.contains(id) { apps.append(id) }
        }
        save()
    }

    private func save() { Prefs.d.set(apps, forKey: Prefs.excludedApps) }
}

private struct AppearancePane: View {
    @AppStorage(Prefs.showAppIcons) private var showAppIcons = true
    @AppStorage(Prefs.showFooter) private var showFooter = true
    var body: some View {
        Form {
            Toggle("Show source app icons", isOn: $showAppIcons)
            Toggle("Show keyboard hints at the bottom of the pop-up", isOn: $showFooter)
        }
        .formStyle(.grouped)
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Clipboard History").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .foregroundStyle(.secondary)
            Text("Your clipboard history stays on this Mac. No network access. No telemetry.")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
        }
        .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    var onDone: () -> Void
    @State private var step = 0
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var clipboard = Permissions.clipboard
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step \(step + 1) of 3").font(.caption).foregroundStyle(.secondary)
            Group {
                switch step {
                case 0: shortcutStep
                case 1: permissionsStep
                default: privacyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                Button(step == 2 ? "Done" : "Continue") { if step == 2 { onDone() } else { step += 1 } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 360)
        .onReceive(timer) { _ in axTrusted = AXIsProcessTrusted(); clipboard = Permissions.clipboard }
    }

    private var shortcutStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Clipboard History from anywhere").font(.title2.weight(.semibold))
            Text("Press this shortcut in any app — even full screen — to see everything you've copied.")
                .foregroundStyle(.secondary)
            ShortcutField()
            HStack(spacing: 6) {
                Text("Presets:").font(.callout).foregroundStyle(.secondary)
                ForEach(ShortcutPreset.all, id: \.label) { preset in
                    Button(preset.label) { KeyboardShortcuts.setShortcut(preset.shortcut, for: .openPanel) }
                        .controlSize(.small).help(preset.help)
                }
            }
            Text("Try it now: press the shortcut.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.title2.weight(.semibold))
            permissionRow(
                ok: clipboard == .allowed || clipboard == .notApplicable,
                title: "Clipboard access",
                detail: clipboard == .denied
                    ? "Clipboard History is blocked from reading the clipboard. Choose “Always Allow”."
                    : "If macOS asks whether Clipboard History can paste from other apps, choose “Always Allow”.",
                button: "Open Settings", action: Permissions.openClipboardSettings)
            permissionRow(
                ok: axTrusted, title: "Auto-paste (optional)",
                detail: "Lets Clipboard History press ⌘V for you. Without it, Clipboard History copies the item and you press ⌘V.",
                button: "Allow…") { PasteService.requestAccessibility(); Permissions.openAccessibilitySettings() }
        }
    }

    private func permissionRow(ok: Bool, title: String, detail: String, button: String,
                               action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary).font(.title3)
                .accessibilityLabel(ok ? "Granted" : "Not granted")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ok { Button(button, action: action) }
        }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Private by design").font(.title2.weight(.semibold))
            Label("Everything stays on this Mac. No network, no telemetry.", systemImage: "lock.laptopcomputer")
            Label("Passwords from password managers are never saved.", systemImage: "key")
            Label("Pause any time from the menu bar.", systemImage: "pause.circle")
            Label("Pin items to keep them forever.", systemImage: "pin")
        }
        .font(.callout)
    }
}

/// One-click shortcut choices in onboarding (Windows switchers asked for something closer to Win+V).
struct ShortcutPreset {
    let label: String, help: String, shortcut: KeyboardShortcuts.Shortcut
    static let all = [
        ShortcutPreset(label: "⌥⌘V", help: "Recommended", shortcut: .init(.v, modifiers: [.option, .command])),
        ShortcutPreset(label: "⌃⌥⌘V", help: "Rarely used by any app", shortcut: .init(.v, modifiers: [.control, .option, .command])),
        ShortcutPreset(label: "⇧⌘V", help: "Closest to Win+V; replaces Paste and Match Style in other apps",
                       shortcut: .init(.v, modifiers: [.shift, .command])),
    ]
}
