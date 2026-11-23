# Decisions

## Phase 1 — Research and spec

### Goal
Turn the brief into a checklist spec (SPEC.md) and pick and verify the platform mechanics. The repo must build from the CLI with `xcodegen` + `xcodebuild` through `scripts/build.sh`, `test.sh`, and `run.sh`.
Done means: SPEC.md has the full parity matrix, every mechanic below has a decision backed by a source, the three scripts run successfully on a stub app, and the risks are listed.

### Assumptions (R = risky)
- A1: Carbon `RegisterEventHotKey` fires over full-screen apps with no TCC permission. Sources: KeyboardShortcuts FAQ ("no permission dialogs", works while an NSMenu is open). Not yet checked against full screen on this Mac (R).
- A2: Reading `NSPasteboard.changeCount` does not trigger the pasteboard-privacy alert. Only reading content does. (R: the header doesn't say. This gets checked on 27.2.1 in Phase 3.)
- A3: The pasteboard-privacy alert is live on macOS 27.2. The SDK header on this machine documents `accessBehavior` as `.default/.ask/.alwaysAllow/.alwaysDeny`, read-only, available from 15.4. Third-party notes say the developer-preview switch was removed in 27.2, which suggests the alert is now enforced (R).
- A4: A `.nonactivatingPanel` with `canBecomeKey = true` takes keystrokes while the previous app stays frontmost and active. This is the standard Spotlight/Alfred pattern.
- A5: Synthesizing ⌘V with `CGEvent.post(tap: .cghidEventTap)` needs Accessibility trust (`AXIsProcessTrusted`).
- A6: This Mac has only an **Apple Development** signing identity and no Developer ID (known from earlier projects). Notarization therefore can't be checked here (R). It goes on the manual list.

### Options and decisions

**D1. Global hotkey**
- (a) `KeyboardShortcuts` SPM 3.x: Carbon hotkeys, a Recorder control, UserDefaults persistence, and a built-in warning for conflicts with system shortcuts and the main menu. Pre-approved.
- (b) Hand-written Carbon code plus a custom recorder: about 300 lines, and the conflict checking would be built from scratch.
- (c) `NSEvent.addGlobalMonitorForEvents`: needs Accessibility/Input Monitoring and can't swallow the key.
- **Decision: (a).** We add our own check for app shortcuts on top (⌘⇧V, ⌥⇧⌘V, and the other paste variants). The default is ⌥⌘V (reasoning in SPEC §3).

**D2. Clipboard change detection**
- (a) Poll `changeCount` on a timer. This is the only public signal; macOS has no pasteboard-changed notification.
- (b) Watch for ⌘C with an event tap: needs permission, misses menu copies and copies made by apps.
- **Decision: (a) with an adaptive interval.** Poll every 0.2 s for 3 s after a change or after the panel opens, then back off to 0.5 s. Use `DispatchSourceTimer` with leeway so the system can coalesce wakeups, which keeps idle CPU at about zero. Content is only read when the count changes.

**D3. Overlay panel**
- **Decision:** an `NSPanel` subclass with `styleMask [.nonactivatingPanel, .fullSizeContentView, .borderless]`, `canBecomeKey = true`, `canBecomeMain = false`, `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `level = .popUpMenu`, `hidesOnDeactivate = false`, `NSVisualEffectView` material `.popover`, and the app as `LSUIElement`. It's built once and reused (hidden instead of closed) to meet the 100 ms budget.
- Alternative rejected: a regular `NSWindow` plus `NSApp.activate`. It steals focus, which breaks requirement 2, and can switch Spaces.

**D4. Paste**
- **Decision:** write the item to the general pasteboard, close the panel, then post a ⌘V keyDown/keyUp pair with `CGEvent` from a `.combinedSessionState` source, after a delay of about 30 ms so the panel's key status is released. Wait for the changeCount to settle before resuming monitoring, so our own write doesn't become a new history item. The write is tagged with `org.nspasteboard.source = Clipboard History`, and the monitor ignores our own changeCount.
- **Fallback** when not trusted: copy only, and show an HUD toast "Copied — press ⌘V". The first time, also show "Enable auto-paste…", which opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.

**D5. Storage**
- (a) SwiftData: opaque file format, hard to test corruption and kill -9 behavior, migrations are awkward, and it adds overhead on macOS 14.
- (b) GRDB: excellent, but a third-party dependency.
- (c) The system `libsqlite3` through a thin wrapper of about 120 lines: WAL mode, `PRAGMA user_version` for migrations, `integrity_check` at startup, no dependency.
- (d) A JSON index file: rewriting all of it on each copy doesn't scale to 5,000 items with search text.
- **Decision: (c).** Metadata lives in SQLite. Each representation is a file in `blobs/<uuid>/`. A corrupt DB is renamed to `.corrupt-<date>` and a new one is created; pinned blobs stay on disk and are recovered where possible (Phase 5).
- Migration plan: a `user_version` integer, and each step is a function `migrate(from:n)` inside a transaction.

**D6. Distribution and sandbox**
- Auto-paste needs `CGEvent.post`, which the App Sandbox doesn't allow without Accessibility, and reading the frontmost app's caret uses AX. So the app is **not sandboxed**. It ships with hardened runtime and Developer ID + notarization (Mac App Store is out).
- Local builds are signed with the Apple Development identity so Accessibility and pasteboard TCC grants survive rebuilds. `make-dmg.sh` (Phase 9) will accept `DEVELOPER_ID=...` and notarize with `notarytool` when it's available. That can't be checked on this machine.

**D7. Project tooling**
- XcodeGen 2.48 (installed via Homebrew) generates the project from `project.yml`. The `.xcodeproj` is gitignored.
- Swift 6 language mode with strict concurrency; the UI is `@MainActor`.
- The UI is SwiftUI hosted in AppKit (`NSHostingView`). The panel, status item, and paste code are AppKit.

**D8. Name:** "Clipboard History" (working name; renaming means changing `project.yml` and the bundle ID). Bundle ID `app.clipboard-history`.

**D9. Privacy filter order** (runs before any content is read):
1. Paused → skip.
2. The frontmost app is on the exclusion list → skip. Default list: 1Password 7/8, Bitwarden, KeePassXC, Keychain Access, Passwords.app, LastPass, Dashlane, Enpass.
3. The pasteboard types include `org.nspasteboard.ConcealedType`, `TransientType`, or `AutoGeneratedType`, or `com.agilebits.onepassword` → skip.
4. Item larger than the cap → skip and add a placeholder notice.
- Logging uses `os.Logger` with `privacy: .private` on all content. Only kinds, sizes, and bundle IDs are logged as `.public`.

### Verification plan (Phase 1 gate)
- `scripts/build.sh` builds the stub app; `scripts/test.sh` runs one placeholder unit test and it passes; `scripts/run.sh` launches the app and `pgrep` finds it.
- Self-review of SPEC.md against the brief: every requirement in §0 maps to a row or budget.

## Risks and open questions
| # | Risk | Mitigation |
|---|---|---|
| K1 | Reading the pasteboard triggers the privacy alert on every copy | Onboarding explains "Always Allow"; detect `.alwaysDeny`/`.ask` and show a banner with a deep link; `changeCount` polling doesn't read content (to be checked) |
| K2 | The ⌥⌘V default collides with Finder's "Move Item Here" | Documented; the recorder makes rebinding easy |
| K3 | Synthetic ⌘V goes to the wrong app if focus changes in the ~30 ms gap | Store the frontmost PID when the panel opens; before posting, check it's still frontmost, otherwise fall back to copy only |
| K4 | Secure input (password fields) blocks synthetic events | `IsSecureEventInputEnabled()` → fall back to copy only with a toast |
| K5 | Panel focus breaks over some full-screen apps (games, video players) | Phase 5 matrix; `.popUpMenu` level |
| K6 | Large images blow the RAM budget | Store the original only on disk; thumbnails ≤ 2× row size via `CGImageSourceCreateThumbnailAtIndex`; LRU thumbnail cache capped at 20 MB |
| K7 | No Developer ID on this machine | The DMG script is parameterized; notarization goes on the manual list |
| K8 | iCloud sync needs a CloudKit container and entitlements that a Development-only signing setup may not provision | Phase 8 last; if blocked → ROADMAP |
| K9 | Caret position via AX isn't available in Electron or many web views | Fall back to the mouse's screen; position near the mouse |
| K10 | Testing on a second display, Stage Manager, or non-US layouts may not be possible here | Listed explicitly as manual steps |

## Phase 2 — Design

**Goal:** DESIGN.md with tokens, layout, every state, keyboard, motion, accessibility, positioning, plus visual proof of each state. Done = a screenshot per state, reviewed against the HIG.
**Assumptions:** `screencapture -l` works from this shell (checked: it captured real screen content, so the shell has Screen Recording). `NSVisualEffectView` vibrancy appears in window captures.
**Options for visual proof:** (a) SwiftUI `#Preview`s: they don't run headless from the CLI and give no image files. (b) `ImageRenderer`: doesn't render AppKit vibrancy, so it's not true to life. (c) The real `PanelController` driven through states and captured with `screencapture -l <windowID>`.
**Decision:** (c). It's a Debug-only `--render-states <dir>` mode (`DebugSupport.swift`), and it uses the production views and panel, so the proof can't drift from the app.
**Verification:** 19 PNGs in `design/`, reviewed by eye. The deviations found were fixed and the states re-rendered (see TESTLOG).

## Phase 3 — Architecture

**Goal:** a working core loop: copy → history → hotkey → panel → paste.
**Decisions:**
- D10. One file per module from Phase 1's list. No protocols or DI containers: `AppDelegate` wires closures. There are no second implementations, so there are no abstractions.
- D11. Pasteboard content is read **off the main thread** (`Task.detached`). The read is thrown away if `changeCount` moved during it. Blobs and thumbnails are written off-main too, and only the metadata insert runs on main. This keeps the 10 MB / 50 MP cases off the UI thread.
- D12. TIFF-only images are converted to PNG. TIFF is dropped when PNG/JPEG is also present, since a 50 MP TIFF is about 200 MB raw.
- D13. Only a curated set of types is kept (file-url, png, jpeg, tiff, color, url, rtf, html, utf8-plain-text). Promised/app-private types are skipped to avoid forcing lazy providers to run (slow, sometimes huge). Paste fidelity is checked in Phase 5 #8.
- D14. Our own writes are tagged with `org.nspasteboard.source` and their changeCount is ignored by the monitor.
- D15. ⌘V is sent with the key code that produces "v" in the **current layout** (UCKeyTranslate), so Dvorak/AZERTY work.
- D16. Automation hooks (Debug only): a distributed notification `app.clipboard-history.debug` with commands `toggle`, `dump`, `key:*`, `query:*`. Release builds don't have them.
- D17. `CLIPBOARD_HISTORY_DATA_DIR` env override lets tests and stress runs use an isolated store without touching real history.

## Phase 4 — Initial testing
**Goal:** unit, UI and smoke tests all green. **Decision:** no XCUITest target. The UI-test runner needs its own Accessibility/Automation grant, which would put a permission prompt on screen with nobody to answer it (the run was unattended overnight). Replaced by `scripts/guitest.py`, which drives the *real* app with real CGEvent keys and mouse plus System Events, and asserts through the Debug state dump. **Risk:** these GUI scripts aren't in CI. **Verification:** 43 unit tests plus the guitest sections (TESTLOG).

## Phase 5 — Intense testing
**Decisions made during the phase:**
- D18. Pinned items stay first and take ⌘1… (design). Holding ⌘ shows the numbers. Revisit if more users report C-10.
- D19. Pasting doesn't reorder history (C-02, Win+V parity). A re-copy of identical content still moves it to the top (dedupe).
- D20. The caret lookup runs off the main thread with a 25 ms budget and asks for the insertion point only (C-01).
- D21. The selection lives in its own `Cursor` object; rows are `Equatable` with a fixed 46 pt height; row buttons have a constant structure. `List` was measured worse than `LazyVStack` and rejected.
- D22. Automation safety: every scripted key or click first checks that the screen is unlocked and that no system prompt (`UserNotificationCenter`, `CoreServicesUIAgent`, `SecurityAgent`) is frontmost; the mouse tool refuses points inside prompt windows. Apps are activated with `open -a` rather than AppleScript, so no new Automation prompts appear.

## Phase 6–8 — User testing, fixes, suggestions
See USER_TEST.md (10 complaints, 10 suggestions), CHANGELOG.md, ROADMAP.md. Ranking for Phase 8 = value ÷ effort: S-03, S-05, S-01, S-02, S-06 (all S effort) were built; S-04 (M, conflicts with type-to-search), S-08/S-09 (L) and S-07/S-10 (low value) went to ROADMAP.

## Phase 9 — Release readiness
- The `make-dmg.sh` Release build is hardened runtime, no sandbox, no `get-task-allow`, with Debug hooks compiled out (checked with `codesign -d --entitlements` and `nm`). Developer ID signing and notarization are parameterized but **unverified**: there's no Developer ID certificate on this Mac.
- Full-screen screenshots in `usertest/` are gitignored. They capture the whole desktop, so they stay local. Early commits (before e4e202f) contain 7 such PNGs in history.
