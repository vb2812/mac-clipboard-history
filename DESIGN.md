# Clipboard History — Design

## Tokens
| Token | Value |
|---|---|
| Panel size | 360 × 480 pt (min 320 × 360), corner radius 12 pt (matches macOS popovers and menus) |
| Material | `NSVisualEffectView` `.popover`, `.behindWindow`, `state = .active` (stays vibrant while the app is inactive, which it always is) |
| Spacing | 4 / 8 / 12 / 16 pt. Panel inset 8 pt, row padding 8 × 6 pt, row gap 2 pt |
| Row radius | 6 pt (selection highlight, like menu items) |
| Type | SF Pro via `.system`: search `.title3`, row `.body` (2 lines max), meta `.caption` secondary, section header `.caption` semibold secondary uppercase-free (Mac style) |
| Color | Only semantic colors: `.primary/.secondary`, `Color.accentColor` selection at 100% with white text (like a menu highlight), separator `Color(nsColor: .separatorColor)` |
| Icons | SF Symbols: `pin.fill`, `trash`, `doc.on.doc`, `photo`, `link`, `paintpalette`, `doc.richtext`, `folder`, `magnifyingglass`, `lock.fill`, `pause.circle` |
| Motion | Panel appears with a 0.12 s ease-out fade plus scale from 0.98, and disappears with a 0.08 s fade. With Reduce Motion it fades only. Row insert/remove uses `.snappy(duration: 0.18)`. Every animation can be interrupted (SwiftUI implicit animations) |

## Pop-up layout (360 × 480)
```
┌──────────────────────────────────────┐
│ 🔍 Search                        ⓧ   │  search field, always focused
│ [Clipboard][Emoji][Symbols][Kaomoji] │  segmented control
│ Pinned                               │  section only if any are pinned
│ ▣ npm run build            2m  📌    │
│ Recent                               │
│ ▣ "Hello world, this is…"  now 📌 🗑 │  pin and trash show on hover/selection
│ ▣ [thumb] 1920×1080 PNG    5m        │
│ ▣ 3 files: a.pdf, b.png…   1h        │
│ ▣ ● #FF6A00                1d        │
│ ─────────────────────────────────────│
│ ↩ Paste  ⇧↩ Plain  ⌘P Pin   ⌫ Delete │  footer hint bar (caption, secondary)
└──────────────────────────────────────┘
```
A row shows the source-app icon (16 pt) with a kind glyph overlaid when there is no app, then the preview (2 lines, or a 32 pt-high thumbnail for images), the relative time, and ⌘1–⌘9 badges on the first nine rows while ⌘ is held.
Emoji/Symbols use a grid of 8 columns with 40 pt cells, a "Recent" row on top, and a name tooltip on hover. Kaomoji uses a grid of 3 columns.

## States
| State | Presentation |
|---|---|
| Loading | Never shown. The store loads metadata synchronously at launch (< 20 ms for 1k rows) and thumbnails load lazily with a neutral placeholder rectangle |
| Empty | Centered `doc.on.clipboard` symbol, "Nothing copied yet", and the caption "Copy something and it will show up here." |
| No search results | "No results for “q”" |
| Long text | Whitespace collapsed, 2 lines, tail truncation. Search matches the first 8 KB |
| Huge image | Thumbnail plus "7952×5304 · PNG · 61 MB" |
| File list | First file's icon, "a.pdf, b.png and 3 more" |
| Secret-hidden | Never stored. If skipped while the panel is open, the footer shows "Skipped a concealed item" for 2 s (no content) |
| Paused | A yellow-tinted banner "Paused — not recording" with a Resume button. The menu-bar icon becomes `pause.circle` |
| Permission missing (clipboard access) | Banner "Clipboard History can't read the clipboard" with an Open Settings button |
| Permission missing (Accessibility) | First paste: toast "Copied — press ⌘V to paste" with a "Turn on auto-paste…" link |
| Shortcut conflict | The recorder warns or blocks inline in Settings (see below) |
| Error (DB) | Banner "History couldn't be loaded. A fresh one was started." The old file is kept as `.corrupt-<date>` |
| Too large | Footer notice "Item over 100 MB not saved" |

## Keyboard
↑/↓ select (grid: ←/→ too) · Return paste · ⇧Return plain-text paste · ⌘1–9 quick paste · ⌘P pin/unpin · ⌫ delete (when search is empty) · ⌘⌫ clear unpinned (asks to confirm) · Tab/⇧Tab next/previous tab · ⌘Y preview · Esc closes the preview, then clears the search, then closes · type to search · right-click for the row menu.

## Positioning
1. If Accessibility is granted and the focused element exposes caret bounds (`kAXBoundsForRangeParameterizedAttribute`), place the panel's top-left 4 pt below the caret.
2. Otherwise place it at the mouse location (top-left at the cursor) on the screen under the mouse.
3. Clamp it to that screen's `visibleFrame` with an 8 pt margin; if it doesn't fit below, flip it above the caret.

## Accessibility
- Every row's label is "<kind>, <preview>, copied <relative time>, from <app>[, pinned]". The pin and delete buttons are labeled and are also available as `accessibilityAction`s, so they work without hovering.
- The list is a single focusable container, and the selection is announced via `accessibilityAddTraits(.isSelected)`.
- Increase Contrast: semantic colors adapt; selection keeps the accent color. Reduce Transparency: `NSVisualEffectView` falls back automatically.
- Text uses semantic text styles, so it follows the system "Text size" setting on macOS 14+.

## Onboarding (3 steps, 480 × 360 window, activated)
1. **Shortcut:** "Open Clipboard History from anywhere", with a recorder prefilled with ⌥⌘V and a "Try it" hint.
2. **Permissions:** two rows, each with a status dot and a button. Clipboard access ("Allow" → System Settings Paste pane) and Accessibility for auto-paste (optional).
3. **Privacy:** "Everything stays on this Mac. Password managers are ignored. Pause any time from the menu bar." Then Done.

## Settings (tabs, 520 × 380)
- **General:** history limit (stepper/picker 10–5000), item size cap, Launch at Login, clear unpinned on quit.
- **Shortcut:** recorder, Reset to Default, clear (the recorder's × button), conflict text.
- **Privacy:** pause toggle, ignored apps list (+/−, add via an app picker), "Hide pop-up in screen recordings and sharing" (on).
- **Appearance:** show source-app icons, show footer hints.
- **About:** version, "No network access. No telemetry."

## Menu-bar menu
Open Clipboard (⌥⌘V) · Pause Recording / Resume · Clear History… · — · Settings… (⌘,) · About Clipboard History · — · Quit Clipboard History (⌘Q).

## HIG self-review (deviations fixed)
- Rejected: a custom accent or brand color in the panel. It now uses the system accent, like menus.
- Rejected: hover-only pin and delete buttons. They were unreachable by keyboard and VoiceOver, so accessibility actions were added.
- Rejected: Space to open Quick Look. It conflicts with typing a space into search. Thumbnails cover previews instead, and Quick Look is moved to the Phase 6 backlog.
