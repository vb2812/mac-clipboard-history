#!/usr/bin/env python3
"""Phase 6 persona sessions: drive the real Debug build like a user and log what happened.
Usage: persona.py <data_dir> <tools_dir> <shots_dir> <persona>   (tools_dir has key, mouse, locked, axdump)
Every line is an observation (OBS) or a measured check (OK/BAD). Nothing is asserted silently."""
import json, os, re, subprocess, sys, time

data_dir, TOOLS, SHOTS, persona = sys.argv[1:5]
HERE = os.path.dirname(os.path.abspath(__file__))
KEY, MOUSE, LOCKED, AX = (f"{TOOLS}/{t}" for t in ("key", "mouse", "locked", "axdump"))

def sh(*a, inp=None):
    return subprocess.run(a, capture_output=True, text=True, input=inp).stdout.strip()
def osa(s): return sh("osascript", "-e", s)
SYSTEM_PROMPTS = ("com.apple.UserNotificationCenter", "com.apple.CoreServicesUIAgent", "com.apple.SecurityAgent")
def frontmost():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    return subprocess.run(["lsappinfo", "info", "-only", "bundleid", asn], capture_output=True, text=True).stdout
def guard():
    if subprocess.run([LOCKED], capture_output=True).returncode != 0: print("ABORT locked"); sys.exit(3)
    if any(b in frontmost() for b in SYSTEM_PROMPTS): print("ABORT system prompt is frontmost; never answer it"); sys.exit(4)
def dbg(c, w=0.15): subprocess.run([f"{HERE}/dbg.sh", c]); time.sleep(w)
def dump():
    dbg("dump", 0.5); return json.load(open(f"{data_dir}/debug-state.json"))
def key(code, *mods): guard(); subprocess.run([KEY, str(code), *mods]); time.sleep(0.05)
def mouse(*a): guard(); subprocess.run([MOUSE, *map(str, a)])
def typ(text): guard(); osa(f'tell application "System Events" to keystroke "{text}"')
def copy(s): sh("pbcopy", inp=s); time.sleep(0.7)
def shot(name): subprocess.run(["screencapture", "-x", f"{SHOTS}/{persona}-{name}.png"]); return f"usertest/{persona}-{name}.png"
def hotkey(): key(9, "opt", "cmd"); time.sleep(0.45)
def open_app(name, *args): subprocess.run(["open", "-a", name, *args]); time.sleep(1.5)
def fs(proc, on):
    osa(f'tell application "System Events" to tell process "{proc}" to set value of attribute "AXFullScreen" of window 1 to {str(on).lower()}'); time.sleep(2.2)
def te_new(text=""):
    osa('tell application "TextEdit" to make new document'); osa(f'tell application "TextEdit" to set text of document 1 to "{text}"')
    open_app("TextEdit"); time.sleep(0.4)
def te_text(): return osa('tell application "TextEdit" to get text of document 1')
def log(kind, task, detail): print(f"{kind} [{persona}] {task} :: {detail}", flush=True)
def ax_rows():
    """Rows and controls of the panel with screen positions (AX top-left points)."""
    pid = sh("pgrep", "-x", "ClipboardHistory").split()[0]
    out = []
    for line in sh(AX, pid, "200").splitlines():
        m = re.match(r"\s*(\w+) \| (.*?)( \[selected\])? @(-?\d+),(-?\d+) (\d+)x(\d+)", line)
        if m: out.append(dict(role=m[1], label=m[2], sel=bool(m[3]), x=int(m[4]), y=int(m[5]), w=int(m[6]), h=int(m[7])))
    return out
def row(label_part):
    return next((r for r in ax_rows() if r["role"] == "AXButton" and label_part in r["label"]), None)

if persona == "designer":
    open_app("Preview", f"{data_dir}/../photo.png"); fs("Preview", True)
    key(0, "cmd"); key(8, "cmd"); time.sleep(1.0)                                 # ⌘A ⌘C in Preview
    hotkey(); d = dump(); p = shot("01-image-in-panel")
    log("OK" if d["kinds"][0] == "image" else "BAD", "D1 copy image from full-screen Preview, open panel",
        f"top kind={d['kinds'][0]} preview={d['previews'][0]!r} visible={d['panelVisible']} front={d['frontmost']} shot={p}")
    key(53); fs("Preview", False)
    for c in ["#3A7BD5", "#00D2FF", "#FF6A00"]: copy(c)
    te_new(""); hotkey(); p = shot("02-colors")
    rows = [r["label"] for r in ax_rows() if r["role"] == "AXButton"][:4]
    log("OBS", "D2 copied 3 hex colors from text", f"rows={rows} shot={p}")
    typ("#3a"); time.sleep(0.4); d = dump(); rows = [r["label"][:30] for r in ax_rows() if r["role"] == "AXButton"][:3]
    log("OK" if rows and "3A7BD5" in rows[0] else "BAD", "D3 search '#3a' (lowercase)", f"results={rows}")
    key(36); time.sleep(0.9)
    log("OK" if te_text() == "#3A7BD5" else "BAD", "D3b Return pastes the match", f"text={te_text()!r}")
    subprocess.run([sys.executable, "-c", "from AppKit import NSPasteboard,NSColor\npb=NSPasteboard.generalPasteboard();pb.clearContents();pb.writeObjects_([NSColor.colorWithSRGBRed_green_blue_alpha_(0.2,0.6,0.4,1)])"])
    time.sleep(1.0); d = dump()
    log("OK" if d["kinds"][0] == "color" else "BAD", "D4 copy an NSColor swatch (like a design app's color well)", f"kind={d['kinds'][0]} preview={d['previews'][0]!r}")
    te_new(""); hotkey(); key(35, "cmd"); time.sleep(0.3)                          # ⌘P pin the swatch
    key(51, "cmd"); time.sleep(0.3); p = shot("03-confirm-clear"); key(36); time.sleep(0.5)  # ⌘⌫ then Return
    d = dump(); log("OK" if d["count"] == d["pinned"] == 1 else "BAD", "D5 pin swatch, ⌘⌫ clear unpinned",
                    f"count={d['count']} pinned={d['pinned']} previews={d['previews']} shot={p}")
    key(53)
    open_app("Preview", f"{data_dir}/../photo.png"); key(0, "cmd"); key(8, "cmd"); time.sleep(1.0)
    te_new(""); hotkey()
    r = row("Image") ; win = osa('tell application "System Events" to tell process "TextEdit" to get {position, size} of window 1')
    if r:
        wx, wy, ww, wh = map(int, win.replace(" ", "").split(","))
        mouse("drag", r["x"] + 120, r["y"] + r["h"] // 2, wx + ww - 120, wy + wh - 100); time.sleep(1.2)
        att = osa('tell application "TextEdit" to count attachments of document 1'); p = shot("04-drag-out")
        d = dump()
        log("OK" if att not in ("", "0") else "BAD", "D6 drag image row out into TextEdit", f"attachments={att!r} panelVisible={d['panelVisible']} shot={p}")
    else:
        log("BAD", "D6 drag image row out", "image row not found in AX tree")
    key(53)
    te_new(""); fs("TextEdit", True); hotkey(); key(19, "cmd"); time.sleep(0.9)   # ⌘2
    d = dump(); log("OBS", "D7 ⌘2 quick paste in full-screen TextEdit", f"text={te_text()!r} top={d['previews'][:2]}")
    fs("TextEdit", False)
    hotkey(); time.sleep(0.2); key(55); p = shot("05-hold-cmd")                        # hold-⌘ badges are flags-driven; just look
    log("OBS", "D8 look at panel with an image + pinned color", f"shot={p}"); key(53)

elif persona == "developer":
    cmds = ["git log --oneline -20", "docker compose up -d --build", "kubectl get pods -n staging | grep api"]
    for c in cmds: copy(c)
    code = "func greet(name: String) {\n    print(\"Hello, \\(name)\")\n}\n"
    copy(code)
    te_new(""); osa('tell application "TextEdit" to activate')
    key(17, "cmd", "shift"); time.sleep(0.6)                                        # ⇧⌘T Make Plain Text
    hotkey(); typ("dock"); time.sleep(0.3); key(36); time.sleep(0.9)
    log("OK" if te_text() == cmds[1] else "BAD", "V1 search 'dock' + Return pastes the docker command", f"text={te_text()!r}")
    te_new(""); hotkey(); key(36); time.sleep(0.9)
    got = te_text()
    log("OK" if got.strip() == code.strip() and "    print" in got else "BAD", "V2 paste multi-line code keeps indentation",
        f"exact={got == code} got={got!r}")
    big = "\n".join(f"2026-11-23T01:{i%60:02d}:00Z INFO request id={i} status=200 path=/api/v1/items" for i in range(1500))
    copy(big); te_new(""); hotkey(); key(36); time.sleep(1.5)
    log("OK" if te_text() == big else "BAD", "V3 copy ~100 KB log, paste back exactly", f"len copied={len(big)} pasted={len(te_text())}")
    open_app("Finder"); osa('tell application "System Events" to keystroke "g" using {command down, shift down}')
    time.sleep(0.8); typ("/etc/hosts"); key(36); time.sleep(1.2); key(8, "cmd"); time.sleep(1.0)
    d = dump(); key(53)
    log("OBS", "V4 copy a file in Finder (⌘C on /etc/hosts)", f"top kind={d['kinds'][0]} preview={d['previews'][0]!r}")
    te_new(""); hotkey(); key(36); time.sleep(0.9)
    log("OBS", "V4b paste that file entry into a TextEdit doc", f"text={te_text()!r}")
    te_new(""); hotkey(); key(36, "shift"); time.sleep(0.9)
    log("OBS", "V5 ⇧Return on the file entry (plain text)", f"text={te_text()!r}")
    hotkey(); key(125); before = dump()["count"]; key(51); time.sleep(0.3); d = dump()
    log("OK" if d["count"] == before - 1 else "BAD", "V6 ⌫ deletes a stale entry", f"count {before}->{d['count']}"); key(53)
    # VS Code (Electron): caret positioning + paste
    open_app("Visual Studio Code"); time.sleep(3); key(45, "cmd"); time.sleep(1.5)  # ⌘N new untitled
    hotkey(); d = dump(); p = shot("07-vscode-panel")
    log("OBS", "V7 open panel in VS Code (Electron)", f"visible={d['panelVisible']} front={d['frontmost']} caretMs={d['lastCaretMs']:.1f} shot={p}")
    typ("kubectl"); time.sleep(0.3); key(36); time.sleep(1.2)
    key(0, "cmd"); key(8, "cmd"); time.sleep(0.8); got = sh("pbpaste")
    log("OK" if got == cmds[2] else "BAD", "V8 paste into VS Code editor", f"editor text={got!r}")
    key(13, "cmd"); time.sleep(1.0); key(2, "cmd"); time.sleep(0.8)                # ⌘W, then ⌘D = Don't Save
    p = shot("08-after-vscode-close"); log("OBS", "V8b closed untitled VS Code tab without saving", f"shot={p}")

elif persona == "windows":
    for s in ["Meeting notes: ship Friday", "https://contoso.example/report", "Q3 numbers.xlsx"]: copy(s)
    te_new(""); key(9, "cmd"); time.sleep(0.7)
    log("OBS", "W1 muscle memory: Win+V on a Mac keyboard is ⌘V", f"TextEdit text={te_text()!r} panelVisible={dump()['panelVisible']}")
    te_new(""); hotkey(); d = dump(); p = shot("01-open")
    log("OK" if d["selection"] == 0 and d["panelVisible"] else "BAD", "W2 ⌥⌘V opens with newest selected (like Win+V)", f"selection={d['selection']} shot={p}")
    r = row("Meeting");
    if r:
        mouse("right", r["x"] + 100, r["y"] + r["h"] // 2); time.sleep(0.6); p = shot("02-right-click")
        menus = sh("osascript", "-e", 'tell application "System Events" to tell process "ClipboardHistory" to count menus')
        log("OBS", "W3 right-click a row expecting the Win+V '…' menu (Pin/Delete/Clear all)", f"menus={menus!r} panelVisible={dump()['panelVisible']} shot={p}")
        key(53)
    rows = ax_rows(); clear = [r for r in rows if "Clear" in r["label"]]
    log("OBS", "W4 look for a visible 'Clear all' in the panel", f"clear controls={[(c['role'], c['label']) for c in clear]}")
    te_new(""); hotkey(); r = row("https://contoso")
    if r:
        mouse("click", r["x"] + 100, r["y"] + r["h"] // 2); time.sleep(0.9)
        log("OK" if te_text() == "https://contoso.example/report" else "BAD", "W5 click an item to paste (Win+V behaviour)", f"text={te_text()!r}")
    hotkey(); key(48); time.sleep(0.3); d = dump(); p = shot("06-emoji-tab")
    log("OBS", "W6 Tab to emoji (Win+V has an emoji tab)", f"tab={d['tab']} shot={p}")
    typ("thumbs"); time.sleep(0.4); key(36); time.sleep(0.8)
    log("OBS", "W6b search 'thumbs' + Return", f"text tail={te_text()[-3:]!r}")
    hotkey(); key(53); time.sleep(0.3); d = dump()
    log("OK" if not d["panelVisible"] else "BAD", "W7 Esc closes", f"visible={d['panelVisible']}")
    hotkey(); key(126); key(126); key(126); time.sleep(0.2); d = dump(); p = shot("08-up-past-top")
    log("OBS", "W8 ↑ from the newest item (Windows wraps? no)", f"selection={d['selection']} shot={p}"); key(53)

elif persona == "student":
    subprocess.run(["open", "-a", "Safari", "https://en.wikipedia.org/wiki/Clipboard_(computing)"]); time.sleep(4)
    fs("Safari", True)
    key(0, "cmd"); key(8, "cmd"); time.sleep(1.2)                                   # copy whole article (rich HTML)
    d = dump(); log("OBS", "S1 copy a whole Wikipedia article from full-screen Safari", f"top kind={d['kinds'][0]} preview={d['previews'][0][:60]!r}")
    hotkey(); d = dump(); p = shot("02-panel-over-safari")
    log("OK" if d["panelVisible"] and d["frontmost"] == "com.apple.Safari" else "BAD", "S2 panel over full-screen Safari", f"visible={d['panelVisible']} front={d['frontmost']} shot={p}")
    key(53); fs("Safari", False)
    cites = ["Smith, J. (2024). Clipboards. MIT Press.", "Doe, A. (2023). Copy and paste. ACM CHI.", "Lee, K. (2022). History UIs. UIST."]
    for c in cites: copy(c)
    te_new(""); fs("TextEdit", True)
    for n, code in [(3, 20), (2, 19), (1, 18)]:
        hotkey(); key(code, "cmd"); time.sleep(0.8); key(36); time.sleep(0.2)
    got = te_text()
    log("OK" if all(c in got for c in cites) else "BAD", "S3 quick-paste 3 citations with ⌘3 ⌘2 ⌘1 in full screen", f"text={got!r}")
    hotkey(); typ("doe"); time.sleep(0.3); d = dump(); rows = [r["label"][:40] for r in ax_rows() if r["role"] == "AXButton"][:2]
    log("OK" if rows and "Doe" in rows[0] else "BAD", "S4 search by author 'doe'", f"rows={rows}"); key(53); key(53)
    te_new(""); hotkey(); typ("clipboard"); time.sleep(0.3); key(36); time.sleep(1.5)
    font = osa('tell application "TextEdit" to get font of character 1 of document 1'); n = len(te_text())
    log("OBS", "S5 paste the article rich into TextEdit", f"chars={n} first-font={font}")
    te_new(""); hotkey(); typ("clipboard"); time.sleep(0.3); key(36, "shift"); time.sleep(1.5)
    font = osa('tell application "TextEdit" to get font of character 1 of document 1')
    log("OBS", "S6 ⇧Return the article as plain text", f"chars={len(te_text())} first-font={font}")
    fs("TextEdit", False)
    osa('tell application "System Events" to tell process "Safari" to keystroke "w" using command down')

elif persona == "privacy":
    secret = "hunter2-%d" % int(time.time())
    subprocess.run([sys.executable, "-c", f'''from AppKit import NSPasteboard
pb=NSPasteboard.generalPasteboard(); pb.clearContents(); pb.declareTypes_owner_(["public.utf8-plain-text","org.nspasteboard.ConcealedType"],None)
pb.setString_forType_("{secret}","public.utf8-plain-text"); pb.setString_forType_("","org.nspasteboard.ConcealedType")'''])
    time.sleep(1.0); hotkey(); d = dump(); p = shot("01-after-concealed")
    log("OK" if secret not in json.dumps(d) else "BAD", "P1 copy a password the way 1Password does (ConcealedType)", f"in history={secret in json.dumps(d)} shot={p}")
    key(53)
    subprocess.run(["defaults", "write", "app.clipboard-history", "paused", "-bool", "true"]); time.sleep(0.5)
    before = dump()["count"]; copy("typed while paused"); d = dump()
    hotkey(); p = shot("02-paused-banner")
    log("OK" if d["count"] == before else "BAD", "P2 pause recording, copy something", f"count {before}->{d['count']} shot={p}")
    key(53); subprocess.run(["defaults", "write", "app.clipboard-history", "paused", "-bool", "false"]); time.sleep(0.5)
    copy("after resume"); d = dump(); log("OK" if d["previews"][0] == "after resume" else "BAD", "P3 resume", f"top={d['previews'][0]!r}")
    subprocess.run(["defaults", "write", "app.clipboard-history", "hideFromCapture", "-bool", "true"]); time.sleep(0.3)
    te_new(""); hotkey(); p = shot("04-capture-hidden"); d = dump()
    log("OBS", "P4 screenshot while the panel is open (hide-from-capture ON)", f"panelVisible={d['panelVisible']} shot={p} (panel should be absent)")
    key(53); subprocess.run(["defaults", "write", "app.clipboard-history", "hideFromCapture", "-bool", "false"])
    lsof = sh("lsof", "-nP", "-a", "-p", sh("pgrep", "-x", "ClipboardHistory").split()[0], "-i")
    log("OK" if not lsof else "BAD", "P5 network sockets held by Clipboard History", f"lsof -i: {lsof or 'none'}")
    perms = sh("stat", "-f", "%Sp %N", f"{data_dir}/history.sqlite", f"{data_dir}/blobs")
    log("OK" if "rw-------" in perms else "BAD", "P6 data file permissions", perms.replace("\n", " | "))
    dbg("settings", 1.2); p = shot("07-settings");
    # click the Privacy tab via AX
    tabs = [r for r in ax_rows() if r["role"] in ("AXRadioButton", "AXButton") and r["label"] == "Privacy"]
    if tabs: mouse("click", tabs[0]["x"] + tabs[0]["w"] // 2, tabs[0]["y"] + tabs[0]["h"] // 2); time.sleep(0.8)
    p = shot("07b-privacy-pane"); log("OBS", "P7 open Settings → Privacy", f"privacy tab found={bool(tabs)} shot={p}")
    osa('tell application "System Events" to tell process "ClipboardHistory" to click button 1 of window "Clipboard History Settings"')
    hotkey(); key(51, "cmd"); key(36); time.sleep(0.4); d = dump(); key(53)
    log("OBS", "P8 ⌘⌫ wipe history", f"count after={d['count']} pinned={d['pinned']}")

elif persona == "firsttime":
    d = dump(); time.sleep(0.5)
    wins = sh("osascript", "-e", 'tell application "System Events" to tell process "ClipboardHistory" to get name of every window')
    p = shot("01-launch")
    log("OBS", "F1 launch fresh (onboarding not done)", f"windows={wins!r} shot={p}")
    key(36); time.sleep(0.6); p = shot("02-step2"); log("OBS", "F2 press Return (Continue)", f"shot={p}")
    key(36); time.sleep(0.6); p = shot("03-step3"); log("OBS", "F3 Return again", f"shot={p}")
    key(36); time.sleep(0.6)
    wins = sh("osascript", "-e", 'tell application "System Events" to tell process "ClipboardHistory" to get name of every window')
    log("OBS", "F4 Return on last step (Done)", f"windows now={wins!r}")
    copy("my first copy"); te_new(""); hotkey(); d = dump(); p = shot("05-first-open")
    log("OK" if d["panelVisible"] else "BAD", "F5 copy something, press the shortcut shown in onboarding", f"visible={d['panelVisible']} top={d['previews'][:1]} shot={p}")
    key(36); time.sleep(0.9); log("OK" if te_text() == "my first copy" else "BAD", "F6 Return pastes", f"text={te_text()!r}")
    bar = sh("osascript", "-e", 'tell application "System Events" to tell process "ClipboardHistory" to get description of every menu bar item of menu bar 2')
    log("OBS", "F7 menu bar item present", f"items={bar!r}")
    dbg("hide"); hotkey(); key(53); hotkey(); d = dump(); key(53)
    log("OBS", "F8 open/close twice quickly", f"visible after reopen={d['panelVisible']}")
