# User test: Phase 6 (2026-11-23, 01:40–02:05, build after commit 6b0cf99)

**Method:** I drove the real Debug build with real key events (CGEvent), mouse events and System Events, with one isolated data folder per persona (`scripts/persona.py`). Each persona's tasks ran end to end against real apps: Preview, TextEdit, Finder, Safari, and VS Code (Electron). Raw output is in TESTLOG.md, and screenshots are in `usertest/`. They're kept locally and gitignored because they capture the whole desktop.

**Not done:**
- No real Figma, Pages, Xcode-editor, Slack, or video call. Those apps aren't installed or need accounts. Preview, TextEdit, VS Code and Safari stood in.
- The "Windows switcher" and "first-time user" are simulated by me: someone who presses ⌘V out of habit, and someone who presses Return through onboarding without reading.
- No real password manager is installed. 1Password's behavior was reproduced by writing `org.nspasteboard.ConcealedType`.

Every complaint below comes from something observed in this run. The full set of persona checks is the next section.

## Tasks run per persona
| Persona | Tasks (OK = matched expectation) |
|---|---|
| Designer | D1 copy image in full-screen Preview → panel shows a thumbnail ✔ · D2 3 hex colors show as swatches ✔ · D3 search `#3a` finds `#3A7BD5`, Return pastes ✔ · D4 copied NSColor shows `#339966` ✔ · D5 pin + ⌘⌫ keeps only the pin ✔ · D6 drag image row into TextEdit: dropped, and TextEdit asked to convert to RTFD ✔ · D7 ⌘2 in full-screen TextEdit pasted the image (⌘1 was the pinned swatch) · D8 visual check |
| Developer | V1 search `dock` → docker command ✔ · V2 multi-line code pasted byte-exact with indentation ✔ · V3 106,889-char log pasted exactly ✔ · V4 Finder ⌘C on a file → `files` item ✔; pastes as attachment, ⇧Return pastes `/private/etc/hosts` ✔ · V6 ⌫ deletes ✔ · V7 panel over VS Code ✔ (position: see C-06) · V8 paste into VS Code editor ✔ |
| Windows switcher | W1 ⌘V just pastes (by design) · W2 opens with newest selected ✔ · W3 right-click → nothing (C-04) · W4 no visible Clear all (C-05) · W5 click pastes ✔ · W6 Tab → Emoji, "thumbs" → 👍 ✔ · W7 Esc closes ✔ · W8 ↑ at top stays at top ✔ |
| Student | S1 copy whole Wikipedia article in full-screen Safari → rich text ✔ · S2 panel over full-screen Safari **failed** (C-01) · S3 ⌘3 ⌘2 ⌘1 citations pasted wrong (C-02) · S4 search "doe" ✔ · S5/S6 rich and plain article paste ✔ |
| Privacy | P1 ConcealedType secret never stored ✔ · P2 paused: copy ignored, banner shown ✔ · P3 resume ✔ · P4 hide-from-capture: panel absent from screenshot ✔ · P5 `lsof -i`: no sockets ✔ · P6 0600/0700 ✔ · P7 Settings → Privacy (C-07) · P8 ⌘⌫ wipe ✔ |
| First-time | F1 onboarding window appears (off-center, C-08) · F2–F4 Return through 3 steps ✔ · F5 ⌥⌘V still works after onboarding ✔ (C-03 regression check) · F6 Return pastes ✔ · F7 menu bar item ✔ · F8 quick reopen ✔ |

## A. Complaints
| ID | Persona | What I tried | What happened | Expected | Sev | Evidence | Status |
|---|---|---|---|---|---|---|---|
| C-01 | Student | ⌥⌘V over full-screen Safari after ⌘A ⌘C on a Wikipedia page | No usable panel: `panel shown in 1300.3 ms`, then `lost key → hiding` (frontmost Safari) | Panel appears within 100 ms and stays | **S1** | log 01:49:16–17; `usertest/student-02-panel-over-safari.png` (1st run) | **Verified fixed**: re-run S2 OK (visible, Safari frontmost); 10 opens over full-screen Safari: first 89.6 ms, then 19.7–30.2 ms |
| C-02 | Student | Quick-paste 3 citations in order with ⌘3, ⌘2, ⌘1 | Got Smith, Lee, Lee: each paste moved the item to the top, so the numbers shifted | Numbers stay put between pastes (Win+V doesn't reorder on paste) | **S2** | persona output S3 (1st run) | **Verified fixed**: re-run S3 pasted Smith, Doe, Lee in order |
| C-03 | First-time (real user report, 2026-11-22) | Pressed ⌥⌘V after onboarding | Nothing. The onboarding shortcut field had focus and silently recorded ⌃⇧V | The shortcut only changes when I click the recorder | **S2** | dump `"hotkey": "⌃⇧V"`; user: "nope it did not pop up" | **Verified fixed** (535da09): F2–F4 pressed Return 3× in onboarding, F5 ⌥⌘V still opens |
| C-04 | Windows | Right-click a row expecting Win+V's "…" menu | Nothing happened | Pin / Delete / Clear all menu | S3 | `usertest/windows-02-right-click.png` (1st run), `menus='0'` | **Verified fixed**: menu shows Paste, Paste as Plain Text, Pin, Delete, Clear All Unpinned… (re-run screenshot) |
| C-05 | Windows | Look for "Clear all" in the panel | Only ⌘⌫ (invisible) or the menu bar menu | A visible Clear all button like Win+V | S3 | AX tree: `clear controls=[]` | **Verified fixed**: footer `AXButton "Clear All"` (asks to confirm) |
| C-06 | Developer | ⌥⌘V in VS Code with the caret on line 1 | Panel opened at the mouse (bottom right), far from the caret | Near the text caret | S3 | `usertest/developer-07-vscode-panel.png`; caret lookup returned nothing (Electron exposes no caret bounds) | **Verified fixed (04:45)**: Clipboard History turns on VS Code's accessibility tree on demand and uses its caret-sized hidden textarea; the panel opened at 640,154, directly under the caret at 640,134 |
| C-07 | Privacy | Read the default "Ignore copies from these apps" list | Uninstalled apps showed as raw bundle IDs (`org.keepassxc.keepassxc`) | Readable names | S3 | `usertest/privacy-07b-privacy-pane.png` | **Verified fixed**: `usertest/p7-settings-privacy-fixed.png` shows 1Password, 1Password 7, Bitwarden, KeePassXC… |
| C-08 | First-time | Welcome window (and Settings) on open | Opened off-center (right of center, partly under other windows) | Centered | S3 | `usertest/firsttime-01-launch.png`, `privacy-07-settings.png` | **Verified fixed**: Settings at x 475–995 and Welcome at 495–975 on a 1470-pt screen (centered) |
| C-09 | Developer (1,000 items) | Hold ↓ deep into a 1,000-item history | Main thread 65–73 % busy at ~15 steps/s (≈ 40 ms/step); lags at the fastest key-repeat rate | Smooth at any length | S3 | `sample` runs in TESTLOG "scroll smoothness" | **Verified fixed (2026-11-23 02:50)**: list is now an NSTableView with SwiftUI rows. Animation Hitches while arrowing 180 rows at 30/s: old LazyVStack 35 hitches / 733 ms / worst 133 ms → table 17–28 hitches / 333–500 ms / **worst 33 ms**. Throughput ≥ 77 steps/s (sender-bound). Click, right-click, hover-delete, drag-out re-verified |
| C-10 | Designer | ⌘1 expecting my newest copy | ⌘1 pasted the pinned swatch; the newest copy was ⌘2 | ⌘1 = newest | S3 | persona D7 (`top=[image, #339966]`) | **Won't fix (by design)**: pinned items are listed first, and holding ⌘ shows the numbers on each row (`design/04-cmd-held.png`). Recorded in DECISIONS D18 |
| C-11 | Privacy / first-time (no Accessibility) | Pick an item with auto-paste unavailable | The "Copied — press ⌘V" toast rendered as an **empty capsule with no text** | A readable hint | **S2** | found 02:55 with `CLIPBOARD_HISTORY_FORCE_COPY_ONLY=1` | **Verified fixed**: AppKit toast with measured size; screenshot shows "Copied — press ⌘V …" |
| C-12 | Accessibility (VoiceOver user) | With VoiceOver on, open Clipboard History and press ↓ | VoiceOver stayed on the search box; moving the selection was silent | Hear each item as I move | **S2** | VoiceOver caption: "You are currently on a text field." | **Verified fixed**: caption "2 of 2. Text, stage manager test, copied 12 minutes ago, from Terminal" |

Not counted as complaints:
- W1 (⌘V pastes instead of opening history): that's macOS's paste. The onboarding presets (S-01) address it.
- The Wikipedia preview reading "WikipediaThe Free…": Safari's own plain-text flavor has no separator there.
- TextEdit's RTFD prompt on image drop: that's TextEdit behavior.

## B. Suggestions
| ID | Persona | Suggestion | User value | Effort | Risk | Status |
|---|---|---|---|---|---|---|
| S-01 | Windows | One-click shortcut presets in onboarding (⌥⌘V, ⌃⌥⌘V, ⇧⌘V "closest to Win+V") | High for switchers | S | Low (⇧⌘V shadows Paste and Match Style; the help text says so) | **Done** |
| S-02 | Designer | "Copy as rgb() / hsl()" on color items | Medium–high | S | Low | **Done** |
| S-03 | Developer | "Paste as plain text by default" (⇧Return keeps formatting) | High | S | Low | **Done** |
| S-04 | Student | Larger preview of a long item | Medium | M | Medium | **Done**: ⌘Y (or right-click → Preview) shows full text, a large image, all files, or a big swatch with rgb/hsl; ↑↓ browse while it's open, Esc closes it |
| S-05 | Privacy | Auto-remove unpinned items after 1 h / 1 day / 1 week / 30 days | High | S | Low | **Done** |
| S-06 | Privacy | Clear unpinned history when the screen locks | Medium–high | S | Low | **Done** |
| S-07 | First-time | One-time hint near the menu bar icon after onboarding | Low–medium | S | Low | ROADMAP (onboarding already teaches the shortcut) |
| S-08 | Windows | Cross-device sync (iCloud) | Medium | L | High (CloudKit entitlements, conflict handling, privacy) | ROADMAP |
| S-09 | Developer | Table-backed list for very large histories (C-09) | Medium | L | Medium | **Done** |
| S-10 | Designer | Drag a multi-file item out as all files | Low–medium | M | Low | **Done, verified by the user** (manual drag to the Desktop) |
