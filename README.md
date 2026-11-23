# Clipboard History

A clipboard history app for the macOS menu bar, with the features of Windows' Win+V. It's built natively with AppKit and SwiftUI, stays local, and never uses the network.

## Install
- **From source:** run `./scripts/build.sh` (needs Xcode 16+ and `brew install xcodegen`). Then open `build/ClipboardHistory.app`, or copy it to /Applications first.
- **DMG:** run `./scripts/make-dmg.sh` to create `dist/Clipboard-History-<version>.dmg`. Set `DEVELOPER_ID` and `NOTARY_PROFILE` to make one that's signed and notarized (see below).

Requires macOS 14 or later.

## First run
A 3-step welcome guide covers:
1. **Shortcut.** The default is **⌥⌘V**. Click the field to record a different one.
2. **Permissions.**
   - *Clipboard access:* if macOS asks whether Clipboard History may paste from other apps, choose **Always Allow**. You can change this later in System Settings → Privacy & Security → Paste from Other Apps.
   - *Auto-paste (optional):* go to System Settings → Privacy & Security → Accessibility and turn on Clipboard History. Without it, choosing an item copies it and shows "press ⌘V".
3. **Privacy.** A summary of what Clipboard History stores (see below).

## Using it
Press the shortcut in any app, including full-screen apps, other Spaces and Stage Manager. The app you were typing in stays active.

| Key | Action |
|---|---|
| ↑ ↓ (← → in grids) | Select |
| Return | Paste |
| ⇧Return | Paste as plain text |
| ⌘1–⌘9 | Quick paste (hold ⌘ to see the numbers) |
| ⌘P | Pin / unpin |
| ⌘Y | Larger preview (↑↓ browse, Esc closes) |
| ⌫ | Delete the item (when search is empty) |
| ⌘⌫ | Clear all unpinned items (asks first) |
| Tab / ⇧Tab | Clipboard · Emoji · Symbols · Kaomoji |
| Esc | Clear the search, then close |
| Typing | Search |

You can also drag an item out of the pop-up into another app, right-click an item for Paste, Paste as Plain Text, Pin, Delete and Clear All, or use the **Clear All** button in the footer. Right-clicking a color offers **Copy as rgb()/hsl()**.

## Options worth knowing
- **Paste as plain text by default** (Settings → General): Return pastes plain text and ⇧Return keeps formatting.
- **Remove unpinned items after** 1 hour / 1 day / 1 week / 30 days (Settings → General).
- **Clear unpinned history when the screen locks** (Settings → Privacy).
- Shortcut presets in the welcome guide: ⌥⌘V (recommended), ⌃⌥⌘V, ⇧⌘V (closest to Win+V; replaces Paste and Match Style).

## Customizing the shortcut
Go to Settings → Shortcut. Click the field, then press the new combination.
- **Reset to Default** restores ⌥⌘V. The **×** clears the shortcut; you can still open Clipboard History from the menu bar.
- Changes apply immediately.
- Combinations used by the system or basic editing (⌘V, ⌘C, ⌘Space…) are blocked. Ones that shadow common app shortcuts (⇧⌘V, ⌥⇧⌘V…) get a warning.
- Known conflict: ⌥⌘V is also Finder's "Move Item Here".

## Privacy
- Everything is stored in `~/Library/Application Support/Clipboard History`. Files are readable only by you (mode 0600/0700). There is no network code, no telemetry and no crash reporting.
- Items that password managers mark as **concealed, transient or auto-generated** (`org.nspasteboard.*`) are never read or saved.
- 1Password, Bitwarden, KeePassXC, Keychain Access, Passwords, LastPass, Dashlane and Enpass are ignored by default. Edit the list in Settings → Privacy.
- **Pause recording** is in the menu bar menu.
- The pop-up is hidden from screen recordings and screen sharing by default. Change this in Settings → Privacy.
- Logs (`log stream --predicate 'subsystem == "app.clipboard-history"'`) contain item kinds, sizes and app IDs, never content.
- **Not encrypted at rest beyond FileVault.** History is protected by your account login and FileVault, like other local app data.

## Building
Builds are signed ad hoc by default, so they work without an Apple developer account. macOS ties the Accessibility (auto-paste) grant to the signature, so with ad-hoc signing you may need to re-grant it after a rebuild. For a stable signature:
```sh
xcodebuild … DEVELOPMENT_TEAM=<your team ID> CODE_SIGN_IDENTITY="Apple Development"
```

## Signing and notarization (Developer ID)
Clipboard History can't use the App Sandbox: auto-paste needs to post a keystroke, and it reads the caret position through Accessibility. So it's distributed with Developer ID and the hardened runtime. To make a release:
```sh
xcrun notarytool store-credentials clipboard-history-notary --apple-id you@example.com --team-id TEAMID
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=clipboard-history-notary ./scripts/make-dmg.sh
```
Release builds don't include `get-task-allow` or any of the Debug-only test hooks.

## Known limitations
- Clipboard changes are detected by polling (0.1–0.5 s), so copies made faster than about 10 per second can collapse into one entry. The last one is always kept.
- App-specific clipboard formats (for example Pages or Figma internals) aren't stored. Text, rich text/HTML, images, files, URLs and colors are.
- Search covers the first 8 KB of each item.
- Unlike Win+V, pinned items are listed first, so ⌘1 is your first pinned item when you have pins.
- Caret positioning needs Accessibility. For Electron apps (VS Code, Slack…) Clipboard History asks the app to turn on its accessibility tree; if an app still reports no caret, the pop-up opens at the focused field or the mouse.
- iCloud sync isn't implemented (see ROADMAP.md).

## Development
`./scripts/test.sh` runs the unit tests and `./scripts/run.sh` builds and launches the app. Debug builds launched with `CLIPBOARD_HISTORY_DATA_DIR` or `CLIPBOARD_HISTORY_DEBUG_HOOKS=1` accept automation commands via `scripts/dbg.sh` and support `--render-states <dir>`. `scripts/guitest.py` and `scripts/soak.py` drive the GUI and soak tests. See DECISIONS.md, TESTLOG.md and SPEC.md.

## License
MIT — see [LICENSE](LICENSE).

Third-party: [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus (MIT), fetched by Swift Package Manager at build time.
