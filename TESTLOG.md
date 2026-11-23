# Test log

## Phase 1 gate — 2026-11-22
Environment: macOS 27.2.1 (26B131), Xcode 27.2 (27B52), Swift 6.4.2, XcodeGen 2.48.0, KeyboardShortcuts 3.1.0.

| Check | Result | Evidence |
|---|---|---|
| `scripts/build.sh` | PASS | `built build/ClipboardHistory.app` |
| `scripts/test.sh` | PASS | `Testing started … tests passed` (1 placeholder test) |
| `scripts/run.sh` launches | PASS | `pgrep -x Clipboard History` → 75686; status item shown (not checked by screenshot) |
| Signed with a stable identity and hardened runtime | PASS | `Authority=Apple Development …`, `flags=0x10000(runtime)`, `TeamIdentifier=<team>` |
| `accessBehavior` API exists in the SDK | PASS | NSPasteboard.h:55–70, 170: read-only, `API_AVAILABLE(macos(15.4))` |
| SPEC self-review: every §0 requirement maps to a row | PASS | Req 1→P1+D1, 2→P2+D3, 3→P3–P21/M1–M9, 4→X1–X4+D9, 5→SPEC §4 |

Issues fixed during the gate: (1) `CODE_SIGN_IDENTITY "Apple Development"` resolved to "Mac Development", so it is now pinned by SHA-1; (2) the team ID was the certificate's user ID instead of the team ID; (3) the test bundle had no Info.plist, so GENERATE_INFOPLIST_FILE is set.
Noise: xcodebuild logs "CoreSimulator is out of date". This doesn't affect macOS builds.

Not checked yet: A1 (hotkey over full screen), A2 (whether reading changeCount triggers the privacy alert), A3 (whether the alert is live on 27.2). These are checked in Phase 3.

## Phase 2 gate — 2026-11-22
`build/ClipboardHistory.app/Contents/MacOS/ClipboardHistory --render-states design/` produced 19 PNGs: empty, list light/dark, ⌘ held (⌘1–9 badges), search, no results, paused, no clipboard access, DB recovered, confirm clear, concealed skipped, too large, emoji, emoji search, symbols (dark), kaomoji, selected row, settings, onboarding.
HIG review found and fixed:
1. The harness leaked banner/notice state between shots. Each shot now resets.
2. The panel opened with a **pinned** item selected; Win+V selects the newest copy. Fixed with `defaultSelection`, which is reused after Esc, search and tab changes.
3. Image thumbnails were centered in their slot, which broke text alignment. They're now leading-aligned.
4. Harness windows were titled "Untitled". They now get real titles.
Result after re-render: PASS (by eye, 4 states spot-checked after the fix: 01, 04, 10, 16).

## Phase 3 gate — core loop, 2026-11-22 (live app, isolated `CLIPBOARD_HISTORY_DATA_DIR`)
| Check | Result | Evidence |
|---|---|---|
| Build | PASS | `built build/ClipboardHistory.app` |
| Unit tests | PASS | `Executed 36 tests, with 0 failures` (store CRUD/dedupe/order/pin/evict/clear/restart, corrupt-DB quarantine, schema version, builder kinds, TIFF→PNG + thumbnail, 1.5 MB text caps, privacy markers/exclusions/pause, shortcut rules, search ranking + diacritics, positioning (multi-screen, clamp, flip), panel keyboard model, pasteboard round trips incl. file lists and plain text, oversize rejection, layout key code) |
| Capture 5 mixed items (`pbcopy`, `osascript` file) | PASS | dump: `kinds: [text, files, color, url, text]`, previews correct, 26 MB footprint |
| Pasteboard-privacy alert on 27.2.1 | **No alert seen** | `accessBehavior` reported `.alwaysAllow` for this fresh bundle ID; all reads succeeded. A2/A3 are therefore **unconfirmed**: the onboarding/banner paths for `.ask/.alwaysDeny` exist but couldn't be triggered here. Manual: System Settings → Privacy & Security → Paste from Other Apps → set Clipboard History to Deny → banner should appear |
| Panel opens, previous app stays frontmost | PASS (partly) | `panelKey: true, frontmost: com.apple.Terminal`. Note: `NSApp.isActive` reads `true` while the non-activating panel is key and `false` after hide; the frontmost app never changes. Whether the caret in the previous app survives is checked in Phase 5 with a real ⌘V |
| Hotkey→visible latency | PASS | after warm-up fix: n=20, first 46.4 ms, p50 18.8, p95 24.8, max 46.4 ms. Before the fix: first 188 ms, second 224 ms (cold SwiftUI layout + icon loads). This measures in-process `show()` through `displayIfNeeded`; it **excludes** Carbon hotkey dispatch and compositor present (≈1 frame). Phase 5 measures end-to-end |
| Paste (no Accessibility → fallback) | PASS | ↓↓↓ Return → `pbpaste` = `https://example.com/page`; item moved to top, count unchanged (own write ignored, no duplicate) |
| Plain-text paste of RTF | PASS | `clipboard info` after ⇧Return: only `utf8/ut16/string` types; text `Bold words` |
| Hide from screen capture (default on) | PASS | full-screen `screencapture` with the panel open did not show it; with the pref off it did |
| Toast visible | NOT VERIFIED | the screen **locked** during this step (screenshot shows the lock screen); all GUI automation stopped at that point |

Commit granularity: slices 1–12 landed as one commit (00507e6) instead of one per slice. That's a process deviation and is noted here.

## Phase 5 (partial, headless) — stress & idle, 2026-11-22
The screen was locked, so only checks that don't need the display were run. App launched with an isolated `CLIPBOARD_HISTORY_DATA_DIR`.
| Check | Result | Evidence |
|---|---|---|
| 10 MB text | PASS | captured; footprint peaked at 73.1 MB, settled to 36.5 MB; app kept answering debug dumps during capture |
| 50 MP image (8660×5774 PNG) | PASS | captured 1.06 s after the copy, off the main thread; preview `8660×5774 · PNG · 162 KB` |
| 5,000-file list | PASS | unit test `testFiveThousandFileList`: read in 0.20 s, preview `file0.txt, file1.txt and 4998 more`. The first live attempt used **nonexistent** paths, and macOS drops file URLs it can't issue sandbox extensions for (`Sandbox extension data required immediately for flavor public.file-url`). That's a test-data error, not an app bug |
| 1,000 items incl. 100 images | PASS (RAM) / **defect found** (capture rate) | footprint **37.0 MB** with 953 items (880 text, 73 images), 9.1 MB on disk. Only 953/1000 captured at 4.5 copies/s because the fast poll was 0.2 s + 50 ms leeway |
| Fix: fast poll 0.1 s, leeway 10% | PASS | re-run: **300/300** captured at 6.7 copies/s |
| 50 copies/s spam (1,000 writes) | Expected loss | the monitor sees at most one change per poll (≤ 10/s), so intermediate copies are skipped and the last one is always kept. Win+V behaves the same at machine speed; humans don't copy at 50/s |
| Idle CPU | PASS | `cputime` 0:22.55 → 0:22.65 over 120 s = **0.08 %**; `top` 0.0 %, 29 MB |
| Not run (needs display or user) | — | panel open during copy spam, scroll at 1,000 items, soak ≥ 1 h (it would overwrite your clipboard for an hour), kill -9 during write, disk-full |

## Phase 5 — GUI session, 2026-11-22 23:06–23:17 (screen unlocked, Accessibility granted by the user)
| Check | Result | Evidence |
|---|---|---|
| Accessibility trust | PASS | dump `axTrusted: true` (the user granted it) |
| Global hotkey via **injected** ⌥⌘V | **Cannot verify by automation** | neither System Events `keystroke` nor a HID-level `CGEventPost` fired the Carbon hotkey. A standalone probe (`hk` registering ⌃⌥⌘F13 + `key` posting it) also timed out, so on macOS 27.2.1 injected events don't trigger Carbon hotkeys in general. It's not a Clipboard History bug. Injected keys *do* reach apps (TextEdit received "ab"). **Manual check needed: press ⌥⌘V physically** |
| Auto-paste, windowed TextEdit | PASS | panel opened (debug hook), ↓ + Return → TextEdit text `alpha`; frontmost stayed `com.apple.TextEdit` |
| Type-to-search + Return | PASS | typed `alp`, Return → `alphaalpha` |
| **Native full-screen TextEdit** | PASS | `AXFullScreen=true`; panel `visible/key: true`, frontmost `com.apple.TextEdit`; Return pasted `alpha`; still full screen afterwards (no Space switch). Screenshot `usertest/fs-textedit-panel.png` shows the panel at the caret on the full-screen Space |
| Full-screen Safari / Preview | **NOT RUN** | macOS showed "Terminal wants access to control Safari". Automation stopped and the prompt was left for the user. Preview never started |

## Correction and fix — 2026-11-22 (later)
- **The earlier claim was wrong.** I wrote that "macOS 27 doesn't fire Carbon hotkeys from injected events". The real cause: Clipboard History's stored shortcut was **⌃⇧V**, not ⌥⌘V, so injected ⌥⌘V had nothing to trigger. Injecting **⌃⇧V** opened the panel (dump: `panelVisible: true`, `hotkey: "⌃⇧V"`). Carbon hotkeys *can* be automated. The standalone `hk` probe's timeout is unexplained (probably its `.prohibited` activation policy) and isn't evidence of anything.
- **Root cause of the changed shortcut (defect, S2):** the onboarding window gave the shortcut recorder first-responder focus on open, so the next key combo the user pressed silently replaced the shortcut. This also explains why physical ⌥⌘V "did nothing". Fix: `AppDelegate.dropInitialFocus` clears first responder after the onboarding and Settings windows open, so the recorder only records after a click. Build + 37 unit tests pass. **Not yet verified on screen** (the user paused GUI automation).
- **Open: first open on the user's real instance measured 210.9 ms** (budget 100 ms). Isolated runs after the warm-up fix measured 46 ms first / 25 ms p95. The cause isn't known yet; it gets re-measured when GUI testing resumes.
- The user stopped a 20-press latency loop mid-run. No further keystrokes were sent.

## Phase 5 #4 — Soak, 2026-11-23 00:00–01:02 (isolated data dir, limit 1000, user away)
`scripts/soak.py`: one random copy every 1–4 s (88% text up to 400 words, 4% hex colors, 8% PNGs up to 3000×2000), with the panel opened and closed on ~10% of copies. Sampled every 60 s.
| Metric | Result |
|---|---|
| Duration / copies / panel opens | 3,670 s / 1,401 copies / 144 opens; ended at 1,000 items (the limit) |
| Footprint | 33.9 MB at start → plateau **46–51 MB** once the limit was reached (t ≥ 2,865 s). The whole-run trend (+9.6 MB/h) reflects history filling to 1,000 items; after the plateau there was no upward trend. **PASS** (< 100 MB) |
| `leaks` at end | `0 leaks for 0 total leaked bytes` **PASS** |
| CPU while copying | **9.1 % average — defect (C-00, perf)**. A 10 s `sample` showed the main thread 29 % busy in SwiftUI rendering: (1) the hidden panel re-rendered on every store change; (2) `NSWorkspace` icons re-rasterized via `NSISIconImageRep` on each render. Fix: `PanelModel.isLive` gates change forwarding to while the panel is visible; icons are rasterized once into a 2× bitmap. Re-measured below |
| Idle CPU (from Phase 5 earlier) | 0.08 % |
Note: `sample` also showed a few CoreSpotlight/`CCDonation` frames in-process (system text-donation machinery). Clipboard History makes no Spotlight calls itself. This is recorded for the privacy review as **unexplained**.

## Phase 5 — GUI pass with fixed build, 2026-11-23 ~01:20–01:45 (isolated data, `scripts/guitest.py`, user away, screen unlocked, `caffeinate`)
**CPU fix verified:** the same soak workload for 10 min on the new build used **1.7 %** CPU (8.30 s of CPU over 498 s), down from 10.2 % over the same 10-minute window in the old build. Footprint 28–40 MB.

| Check | Result | Evidence |
|---|---|---|
| Hotkey: 20 combos (⌥⌘V, ⌃⇧V, ⌃⌥⇧⌘V, ⌃⌥Space, ⌥⌘C, ⌃⌥⌘K, ⌃F5, ⌥F12, ⌃⌥⇧⌘F1, ⇧⌘1, ⌃⌥0, ⌘`, ⌃⌥⇧L, ⌥⌘/, ⌃⌘Return, ⌥⌘←, ⌃⌥⌘D, ⌃⇧Tab, ⌥⌘;, ⌃⌥⌘=) | PASS 20/20 | First run had 4 failures (3 F-keys, ⌥⌘←). Cause: my injector didn't set the `fn`/`numericPad` flags a real keyboard sends with F-keys and arrows. Re-injected with those flags: all 4 opened the panel |
| Cleared shortcut does nothing | PASS | `visible=False hotkey=none` |
| Hotkey while Settings window open | PASS | panel opened |
| Persistence across relaunch | PASS | set ⌃⌥⌘K → relaunch → `hotkey ⌃⌥⌘K`, pressing it opened the panel |
| Hotkey→visible latency, **real Carbon hotkey**, over TextEdit with AX caret lookup | **PASS** | n=30, p50 **20.6 ms**, p95 **27.3 ms** (budget 100 ms). Still excludes compositor present (~1 frame at 60–120 Hz) |
| Rich paste keeps formatting (TextEdit → Clipboard History → TextEdit) | PASS | `font=Helvetica-Bold` |
| ⇧Return plain text | PASS | text kept, `font=Helvetica` (bold removed). The first attempt failed from a test-order bug (the item had moved to the top) |
| ⌘3 quick paste | PASS | pasted the 3rd newest |
| Emoji tab → search "rocket" → Return | PASS | `🚀` inserted |
| File copy captured | PASS | `kinds[0]=files preview=hosts` (the first attempt waited only 0.7 s, too short for the slow-poll window) |
| Image paste into TextEdit | PASS | attachment character `￼` inserted; screenshot `usertest/paste-image-textedit.png` |
| Copy while panel open | PASS | count 8→9 live, panel stayed open (`usertest/panel-live-update.png`) |
| Type-to-search | PASS | typed `w` → `query: 'w'` |
| Click in another window closes the panel | PASS | CGEvent click in TextEdit → `panelVisible: False`, TextEdit frontmost |
| Switching apps closes the panel | PASS | Finder activated → hidden |
| **Full-screen Preview** | PASS | `fs=true→true visible key front=com.apple.Preview` (`usertest/fs-preview-panel.png`) |
| **Full-screen TextEdit** | PASS | same (`usertest/fs-textedit-panel.png`) |
| Concealed-type secret never stored or logged | PASS | not in list, `grep -r` of data dir: none, not in `log show` |
| Normal content not in system log | PASS | 13 log lines, none containing content |
| Clipboard text not indexed by Spotlight | PASS | unique marker shown in panel, `mdfind` 20 s later: none |
| File permissions | PASS | `-rw-------` DB, `drwx------` blobs |

## Phase 5 — data integrity, a11y tree, scroll at 1,000 (2026-11-23 ~01:50–02:40)
| Check | Result | Evidence |
|---|---|---|
| kill -9 during writes, 5 rounds (3 MB RTF + text at 7/s, killed at random 1.0–1.9 s) | PASS | relaunch: 42 items, `PRAGMA integrity_check` = ok, 42 rows = 42 blob dirs, no missing blobs, no `.corrupt` files |
| Disk full (6 MB HFS+ image as data dir, filled with `dd`) | PASS | 4.3 MB image copy → `could not save item: … Code=640 "You can't save the file "0" because the volume … is out of space"` (log, error level); app kept running; text still saved; after freeing space, new copies saved; integrity ok |
| Log readability check | Note | In zsh, `log` is a **shell builtin**, so my earlier ad-hoc `log show` calls never reached `/usr/bin/log`. All `guitest.py` privacy checks call `/usr/bin/log` and are valid. Content probe `log probe text 12345`: 0 occurrences in the unified log |
| VoiceOver/AX tree (walked with AXUIElement, 1,000 items) | PASS | `AXTextField "Search"`, `AXRadioGroup "Category"` with 4 `AXRadioButton`s, `AXHeading "Recent"`, rows are `AXButton "Text, <preview>, copied <time>, from <app>"`, the selected row exposes `AXSelected`, and rows have actions `Delete`, `Pin`, `Paste as plain text` |
| Scroll smoothness at 1,000 items (300 ↓ presses at ~15/s, `sample` of the main thread) | **⚠️ partial** | Start: **99 %** main-thread busy (every row observed the model and re-rendered; the filtered list was recomputed on each render). After fixes (cached `clips`/`glyphs`; selection moved to a separate `Cursor` that only rows observe; `Equatable` rows; fixed 46 pt rows; action buttons no longer inserted/removed): **65–73 %**. Remaining cost is SwiftUI `LazyVStack` placement walking from index 0 on each scroll (cost grows with depth). That's ≈ 40 ms per step deep in the list: fine at default key repeat (~11/s), but it lags at the fastest repeat rate. `List` was tried and was worse (100 %, per-row hosting views + focus-loop rebuilds); a manual NSScrollView scroller only reached 65 % and was reverted. **Upgrade path: NSTableView-backed list (ROADMAP).** At the default limit of 25 items the cost is negligible |

## Phase 6–8 — persona sessions and fixes, 2026-11-23 01:40–02:15
Details are in USER_TEST.md. Re-tests after the fixes:
- C-01 (S1): first run `panel shown in 1300.3 ms` then lost key over full-screen Safari. After the fix, persona S2 passed; 10 opens over full-screen Safari: 89.6 ms first, then 19.7–30.2 ms. `usertest/student-02-panel-over-safari.png` (01:53) shows the panel over Safari in true full screen.
- C-02 (S2): ⌘3 ⌘2 ⌘1 → `Smith…\nDoe…\nLee…` (was Smith, Lee, Lee).
- C-04/C-05: AX shows the context menu items and `AXButton "Clear All"`; clicking a row pastes it (W5 rerun `https://contoso.example/report`).
- C-07/C-08: screenshots `p7-settings-privacy-fixed.png`; window frames Settings 475–995, Welcome 495–975 (screen 1470 pt).
- Phase 8 live checks: simulated `com.apple.screenIsLocked` with clear-on-lock → 0 items; 1-hour expiry → the stale item was removed on relaunch, the fresh one kept; right-click a color → "Copy as rgb(255, 106, 0)" → clipboard `rgb(255, 106, 0)`; clear-on-quit → only the pinned item remained.
- Automation safety incident: a VS Code system prompt ("would like to access files on a removable volume") appeared during the developer persona. It came from VS Code, not Clipboard History. **It was left unanswered for the user.** One scripted click landed on the prompt's empty top edge, not a button. After that, the mouse tool was hardened to refuse clicks inside prompt windows (verified: `REFUSED`, rc 5).

## Phase 9 — final verification on the release-candidate build (02:15–02:30)
| Check | Result |
|---|---|
| Unit tests | **43/43 pass** |
| GUI hotkey suite | **23/23 pass** (20 combos incl. F-keys with `fn` and arrows with `fn+numpad`, cleared, while Settings open) |
| Hotkey→visible (30 real-hotkey opens over TextEdit) | **p50 29.0 ms, p95 37.9 ms, max 42.6 ms**; caret p50 1.9 ms |
| GUI paste suite | 5/5 pass + image attachment (info) |
| GUI panel and privacy suites | pass (copy while open, type-to-search, click/app-switch closes, concealed not stored or logged, not in Spotlight, file perms) |
| Full screen re-run | **⚠️ could not run.** macOS ignored every request to enter full screen (`AXFullScreen` set and ⌃⌘F both stayed `false`) while the unanswered VS Code system prompt was on screen. Last verified at 01:53 (Safari) and 01:2x (TextEdit, Preview) |
| Idle CPU | 0.04 s of CPU over 90 s = **0.04 %** |
| Footprint | 51.1 MB after the full GUI session |
| Release DMG | `dist/Clipboard-History-0.1.0.dmg`, `codesign --verify --strict` ok, 0 `get-task-allow`, 0 debug symbols |

## Continuation, 2026-11-23 02:20–02:50 (user said "keep going, finish everything")
- The VS Code prompt was gone, but **entering full screen still failed** (`AXFullScreen` set, ⌃⌘F and the green button all left `false`), so that wasn't the cause. Not yet explained; see the next block.
- The user was active (a virtual machine window in front). GUI work then ran only behind `scripts/idlegate.sh` (no HID input for ≥ 40 s before each batch).
- **Keyboard layouts (no system change):** `testKeyCodeForVOnOtherLayouts` reads layout data of installed-but-not-enabled layouts. ⌘V key: US 9, Dvorak 47, Dvorak–QWERTY⌘ 9, French 9, German 9, Colemak 9. The translation now holds ⌘ down, which fixes Dvorak–QWERTY⌘ (it would have sent the Dvorak "v" key, which is ⌘. there). PASS.
- **C-09 table list:** `scripts/scrollbench.sh` (300 ↓ at ~80/s from one process): old and new both catch up within 0.16 s (≥ 77 steps/s, sender-bound), so the earlier "% busy" metric never meant lost keys. `scripts/hitchbench.sh` + `hitchsum.py` (Instruments Animation Hitches, 180 ↓ at 30/s, the fastest key repeat): **old 35 hitches, 733 ms, worst 133 ms; new 17 / 333 ms / 33 ms and 28 / 500 ms / 33 ms.** Regression: guitest paste+panel 8/8 pass; mouse click-to-paste `beta row` ✔, context menu 5 items ✔, hover trash 12→11 ✔, image drag-out → attachment ✔. Unit tests 44/44.
- **High-contrast appearances** (`design/22`, `design/23`) and **preview states** (`design/18`–`19c`) rendered. The first table renders showed 2 regressions (header centered; list opened scrolled past Pinned), both fixed and re-rendered. ⌘-held badges went missing with the table's partial reload; now a full reload on ⌘ change, re-rendered OK.
- **VoiceOver tree through the table:** `AXHeading "Recent"`, `AXButton "Text, second, copied now, from Preview" [selected]`. Still exposed. PASS.
- **No-Accessibility path** (`CLIPBOARD_HISTORY_FORCE_COPY_ONLY=1`): item copied (`pbpaste` = `toast test`), nothing pasted. **Toast rendered empty: new defect C-11 (S2)**, fixed (AppKit toast), re-verified by screenshot.
- **Launch at Login:** `SMAppService.mainApp.status` 3 (notFound) → `register()` → 1 (enabled; `sfltool dumpbtm` lists the app as enabled, allowed, notified) → `unregister()` → 0. PASS, and left **off**.
- Unit tests 45/45 (adds `testPreviewKeys`).
- Full screen still can't be entered by any method tried (AX attribute, ⌃⌘F, green button). A View-menu attempt was aborted because the user became active. GUI work stopped at 03:08 when the idle gate saw user input.

## Stage Manager and VoiceOver (user asked me to run them), 2026-11-23 04:25–04:40
- Test helpers now live in `scripts/tools/` (built by `scripts/build-tools.sh`). The scratch folder holding them had been wiped.
- Guard bug found and fixed: my synthetic keys reset `HIDIdleTime`, so "user idle" checks after my own key presses aborted runs. The guard now checks the frontmost app and the lock state before every key.
- First final-check run (before these fixes) is **invalid**: the shortcut write failed, Terminal was frontmost, and keys went to Terminal (probably ⌘N → an extra "-zsh" window, and the text "line one", not executed). The user closed it.
- **Stage Manager** (already on, `GloballyEnabled=1`): ⇧⌘V over TextEdit → panel visible + key, TextEdit frontmost; ↓ Return pasted `stage manager test`. **PASS**.
- **VoiceOver** (turned on with ⌘F5, off afterwards; verified `pgrep VoiceOver` = none): the panel opens, ↓ moves the selection, Return pastes with VO running. **Defect C-12 (S2):** VO stays on the search field, so ↓/↑ were silent. **Fixed:** announces "N of M. <kind>, <preview>, copied <time>, from <app>" on each selection change when VoiceOver is on. Re-verified: VO caption panel showed "2 of 2. Text, stage manager test, copied 12 minutes ago, from Terminal" (`usertest/voiceover-announce.png`).
- Also observed: right after VoiceOver is toggled, injected keys were briefly dropped (`osascript is not allowed assistive access` once). It recovered within a minute, and this was environmental.

## Remaining checks, 2026-11-23 04:36–04:55
- **Full screen:** still can't be entered on this Mac by any method: AX attribute, ⌃⌘F, the green button (on macOS 27 it opens a Move/Fill/Full Screen menu), or **Full Screen → Entire Screen** from that menu. Turning Stage Manager off (`defaults write com.apple.WindowManager GloballyEnabled -bool false`) didn't help, and it was restored to on immediately after. This is a system-level state, not Clipboard History. Clipboard History's over-full-screen behavior was verified earlier (Safari 01:53, TextEdit, Preview). **Manual re-check after a restart is suggested.**
- **VS Code caret (C-06):** VS Code's focused-element query failed (`-25204`) until an assistive app sets `AXManualAccessibility` on it. Clipboard History now does that once. The focused element is a zero-width hidden textarea at the caret (640,134 0×18), now treated as the caret. **Verified:** panel opened at 640,154 (directly below the caret) instead of at the mouse (625,339). Unit test extended.
- **Multi-file drag (S-10):** the first approach (subclassing NSHostingView) never received drag events, so it was replaced with a transparent catcher view over file rows (with `acceptsFirstMouse`). Logged: `drag session started with 3 items` every time. **1 of 5 automated drags into a Finder folder delivered all three files (`a.txt b.txt c.txt`)**; the other 4 started a session but the synthetic drop didn't land. Click-to-paste on a file row (3 attachments in TextEdit) and the right-click menu (6 items) work through the catcher. **⚠️ Needs a manual drag check.**
- **Reduce Motion** (`CLIPBOARD_HISTORY_REDUCE_MOTION=1`): `animated False`, `alpha 1` right after show (no fade); normal launch `animated True`. PASS.
- Unit tests 46/46.
- **User check, 2026-11-23:** the user reported "it worked" for the manual multi-file drag-out (copy 2–3 files in Finder → ⇧⌘V → drag the item to the Desktop). S-10 is verified.
- **Re-verification by me (user asked), 2026-11-23:** full screen still can't be entered by automation (`AXFullScreen` stays false), so it was not re-verified this round; last verified 01:53 (Safari) and earlier (TextEdit, Preview). Multi-file drag: 5 more synthetic drags each started a 3-item session, but no drop landed (Finder doesn't accept these synthetic drops reliably). The feature stays verified by the user's manual drag and the one earlier automated success.
