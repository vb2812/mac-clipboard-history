# Changelog

## 0.1.0 — 2026-11-23

### Fixed (from user testing, USER_TEST.md)
- C-01 (S1): The pop-up no longer stalls or fails to appear over full-screen Safari. The caret lookup runs on a background thread with a 25 ms budget, and it asks only for the insertion point, not the whole selection. Regression test: `PositionTests.testCaretLookupIsTimeBoxed`.
- C-02 (S2): Pasting no longer moves an item to the top, so ⌘1–9 positions stay stable between pastes (Win+V parity). Re-verified with the student persona S3.
- C-03 (S2): The onboarding and Settings windows no longer give the shortcut recorder focus when they open, so a stray key press can't silently replace the shortcut. Re-verified with first-time persona F2–F5.
- C-04: Right-click menu on rows: Paste, Paste as Plain Text, Pin/Unpin, Delete, Clear All Unpinned…
- C-05: Visible "Clear All" button in the pop-up footer. It asks for confirmation and keeps pinned items.
- C-07: The ignore list shows readable names for password managers that aren't installed.
- C-08: Settings and Welcome windows open centered on the active screen.

- C-09: The clip list is an NSTableView hosting the SwiftUI rows. Worst hitch while holding ↓ through 1,000 items went from 133 ms to 33 ms. ⌘V is sent on the right key for Dvorak, Dvorak–QWERTY ⌘, AZERTY, QWERTZ and Colemak (unit-tested against the installed layouts).

- C-11 (S2): The "Copied — press ⌘V" toast (shown when auto-paste isn't possible) rendered empty; it's rebuilt in AppKit with a measured size. The secure-input wording now checks secure input itself.
- C-12 (S2): With VoiceOver on, moving the selection announces "N of M" plus the item.
- C-06: Where an app reports no caret (Electron), the pop-up anchors at the focused text field instead of the mouse.
- S-10: Dragging a file-list item drags all its files.
- Settings can be reached without the menu bar icon: open Clipboard History again, ⌘, in the pop-up, or the gear button.
- S-04: ⌘Y preview pane (text, image, files, color with rgb/hsl).

### Performance and robustness (from Phase 5)
- The hidden pop-up no longer re-renders on every copy, and app icons are rasterized once. CPU while copying dropped from 10.2 % to 1.7 % (soak).
- Cached clip and glyph lists, a selection cursor that only visible rows observe, equatable fixed-height rows, and action buttons that are no longer inserted and removed on selection. Main-thread load while arrowing through 1,000 items went from 99 % to 65–73 % (see C-09).
- The fast poll is now 0.1 s, so rapid copies (≤ 10/s) aren't dropped.
- The pop-up is pre-rendered at launch, so the first open takes ~45–90 ms instead of 188 ms.
- Startup cleanup of orphaned blob folders no longer deletes items captured in the first moments after launch.
- Release builds no longer carry `get-task-allow`, which notarization rejects.

### Added (Phase 8 suggestions)
- S-01: Shortcut presets in onboarding (⌥⌘V, ⌃⌥⌘V, ⇧⌘V).
- S-02: "Copy as rgb()/hsl()" on color items.
- S-03: "Paste as plain text by default" setting (⇧Return keeps formatting).
- S-05: Remove unpinned items after 1 hour / 1 day / 1 week / 30 days.
- S-06: Clear unpinned history when the screen locks.

### Initial feature set
Menu bar app with a non-activating pop-up that works over full-screen apps and in all Spaces. It covers:
- **History types:** text, rich text, HTML, images, files, URLs and colors.
- **Organizing:** pin, delete, clear, and search.
- **Pasting:** paste, plain-text paste, and ⌘1–9 quick paste.
- **Character tabs:** Emoji, Symbols and Kaomoji, each with recents.
- **Privacy:** concealed/transient/auto-generated types are ignored, plus an app exclusion list, pause, and hiding the pop-up from screen capture.
- **Setup:** Launch at Login and onboarding.
