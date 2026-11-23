#!/usr/bin/env python3
"""GUI test pass against a running Debug Clipboard History (isolated CLIPBOARD_HISTORY_DATA_DIR).
Drives keys via a CGEvent helper, the app via scripts/dbg.sh, and TextEdit/System Events via osascript.
Aborts immediately if the screen is locked. Prints one PASS/FAIL/INFO line per check.
Usage: guitest.py <data_dir> <key_bin> <locked_bin> <shots_dir> [section ...]"""
import json, os, subprocess, sys, time

data_dir, KEY, LOCKED, SHOTS = sys.argv[1:5]
sections = set(sys.argv[5:])
HERE = os.path.dirname(os.path.abspath(__file__))
results = []

def sh(*a, check=False):
    return subprocess.run(a, capture_output=True, text=True, check=check).stdout.strip()

def osa(script):
    return sh("osascript", "-e", script)

SYSTEM_PROMPTS = ("com.apple.UserNotificationCenter", "com.apple.CoreServicesUIAgent", "com.apple.SecurityAgent")
def frontmost():
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    return subprocess.run(["lsappinfo", "info", "-only", "bundleid", asn], capture_output=True, text=True).stdout
def guard():
    if subprocess.run([LOCKED], capture_output=True).returncode != 0:
        print("ABORT screen locked"); sys.exit(3)
    if any(b in frontmost() for b in SYSTEM_PROMPTS): print("ABORT system prompt is frontmost; never answer it"); sys.exit(4)

def dbg(cmd, wait=0.15):
    subprocess.run([f"{HERE}/dbg.sh", cmd]); time.sleep(wait)

def dump():
    dbg("dump", 0.5)
    return json.load(open(f"{data_dir}/debug-state.json"))

def key(code, *mods):
    guard(); subprocess.run([KEY, str(code), *mods])

def report(ok, name, evidence):
    line = f"{'PASS' if ok is True else ('FAIL' if ok is False else 'INFO')} {name} :: {evidence}"
    results.append(line); print(line, flush=True)

def front(app):
    guard(); osa(f'tell application "{app}" to activate'); time.sleep(0.8)

def textedit_new(text=""):
    osa('tell application "TextEdit" to make new document')
    osa(f'tell application "TextEdit" to set text of document 1 to "{text}"')
    front("TextEdit")

def textedit_text():
    return osa('tell application "TextEdit" to get text of document 1')

def copy(s):
    subprocess.run(["pbcopy"], input=s, text=True); time.sleep(0.6)

def screenshot(name):
    subprocess.run(["screencapture", "-x", f"{SHOTS}/{name}.png"])

CARBON = {"cmd": 256, "shift": 512, "opt": 2048, "ctrl": 4096}

# ---------------------------------------------------------------- hotkeys
if not sections or "hotkey" in sections:
    combos = [  # (label, keycode, mods)
        ("⌥⌘V", 9, ["opt", "cmd"]), ("⌃⇧V", 9, ["ctrl", "shift"]), ("⌃⌥⇧⌘V", 9, ["ctrl", "opt", "shift", "cmd"]),
        ("⌃⌥Space", 49, ["ctrl", "opt"]), ("⌥⌘C", 8, ["opt", "cmd"]), ("⌃⌥⌘K", 40, ["ctrl", "opt", "cmd"]),
        # F-keys and arrows carry fn (and numpad for arrows) on a real keyboard; CARBON ignores those flags.
        ("⌃F5", 96, ["ctrl", "fn"]), ("⌥F12", 111, ["opt", "fn"]), ("⌃⌥⇧⌘F1", 122, ["ctrl", "opt", "shift", "cmd", "fn"]),
        ("⇧⌘1", 18, ["shift", "cmd"]), ("⌃⌥0", 29, ["ctrl", "opt"]), ("⌘`", 50, ["cmd"]),
        ("⌃⌥⇧L", 37, ["ctrl", "opt", "shift"]), ("⌥⌘/", 44, ["opt", "cmd"]), ("⌃⌘Return", 36, ["ctrl", "cmd"]),
        ("⌥⌘←", 123, ["opt", "cmd", "fn", "numpad"]), ("⌃⌥⌘D", 2, ["ctrl", "opt", "cmd"]), ("⌃⇧Tab", 48, ["ctrl", "shift"]),
        ("⌥⌘;", 41, ["opt", "cmd"]), ("⌃⌥⌘=", 24, ["ctrl", "opt", "cmd"]),
    ]
    textedit_new("")
    for label, code, mods in combos:
        dbg(f"shortcut:{code}:{sum(CARBON.get(m, 0) for m in mods)}", 0.3)
        dbg("clearlatency")
        front("TextEdit")
        key(code, *mods); time.sleep(0.5)
        d = dump()
        ok = d["panelVisible"] and len(d["latenciesMs"]) == 1 and d["frontmost"] == "com.apple.TextEdit"
        report(ok, f"hotkey {label}", f"visible={d['panelVisible']} opens={len(d['latenciesMs'])} hotkey={d['hotkey']} front={d['frontmost']}")
        dbg("hide", 0.3)
    # cleared shortcut must not open
    dbg("shortcut:none", 0.3); dbg("clearlatency"); front("TextEdit")
    key(9, "opt", "cmd"); time.sleep(0.5); d = dump()
    report(not d["panelVisible"] and d["hotkey"] == "none", "hotkey cleared", f"visible={d['panelVisible']} hotkey={d['hotkey']}")
    # works while Settings is open
    dbg("shortcut:reset", 0.3); dbg("settings", 1.0); dbg("clearlatency")
    key(9, "opt", "cmd"); time.sleep(0.6); d = dump()
    report(d["panelVisible"], "hotkey while Settings open", f"visible={d['panelVisible']} hotkey={d['hotkey']}")
    dbg("hide", 0.3)
    osa('tell application "System Events" to tell process "ClipboardHistory" to click button 1 of window "Clipboard History Settings"')
    # end-to-end latency with the real hotkey, 30 presses, frontmost TextEdit (AX caret lookup included)
    front("TextEdit"); dbg("clearlatency"); carets = []
    for _ in range(30):
        key(9, "opt", "cmd"); time.sleep(0.35); carets.append(dump()["lastCaretMs"]); key(53); time.sleep(0.25)
    lat = sorted(dump()["latenciesMs"])
    if lat:
        p95 = lat[max(0, int(len(lat) * 0.95) - 1)]
        report(p95 < 100, "hotkey→visible latency (30 real-hotkey opens over TextEdit)",
               f"n={len(lat)} p50={lat[len(lat)//2]:.1f}ms p95={p95:.1f}ms max={lat[-1]:.1f}ms caret p50={sorted(carets)[len(carets)//2]:.1f}ms")

# ---------------------------------------------------------------- paste fidelity
if not sections or "paste" in sections:
    dbg("shortcut:reset", 0.2)
    # rich text: make a bold RTF in TextEdit, copy it from TextEdit itself
    osa('tell application "TextEdit" to make new document')
    osa('tell application "TextEdit" to set text of document 1 to "Bold heading"')
    osa('tell application "TextEdit" to set font of text of document 1 to "Helvetica-Bold"')
    front("TextEdit")
    key(0, "cmd"); key(8, "cmd"); time.sleep(0.8)          # ⌘A ⌘C
    copy("filler one")                                      # push it down the list
    textedit_new("")
    key(9, "opt", "cmd"); time.sleep(0.4)
    d = dump()
    dbg("key:down"); dbg("key:enter", 0.9)
    font = osa('tell application "TextEdit" to get font of character 1 of document 1')
    report(textedit_text() == "Bold heading" and "Bold" in font, "rich paste keeps formatting (TextEdit→TextEdit)",
           f"text={textedit_text()!r} font={font}")
    textedit_new("")
    # pasting doesn't reorder (C-02), so "Bold heading" is still second
    key(9, "opt", "cmd"); time.sleep(0.4); dbg("key:down"); dbg("key:shiftEnter", 0.9)
    font2 = osa('tell application "TextEdit" to get font of character 1 of document 1')
    report(textedit_text() == "Bold heading" and "Bold" not in font2, "⇧Return pastes plain text",
           f"text={textedit_text()!r} font={font2}")
    # quick paste ⌘3 and emoji insert
    for s in ["q-one", "q-two", "q-three"]: copy(s)
    textedit_new("")
    key(9, "opt", "cmd"); time.sleep(0.4); key(20, "cmd"); time.sleep(0.9)   # ⌘3
    report(textedit_text() == "q-one", "⌘3 quick paste", f"text={textedit_text()!r} (expected 3rd newest)")
    textedit_new("")
    key(9, "opt", "cmd"); time.sleep(0.4); key(48); time.sleep(0.2)   # Tab → Emoji
    dbg("query:rocket", 0.3); dbg("key:enter", 0.9)
    report(textedit_text() == "🚀", "emoji tab insert", f"text={textedit_text()!r}")
    # file list paste into TextEdit (inserts file reference / name)
    osa('set the clipboard to (POSIX file "/etc/hosts")'); time.sleep(1.5)
    d = dump(); report(d["kinds"][0] == "files", "file copy captured", f"kinds[0]={d['kinds'][0]} preview={d['previews'][0]}")
    # image round trip: copy png, paste into TextEdit rich doc
    subprocess.run(["osascript", "-e", f'set the clipboard to (read (POSIX file "{data_dir}/../blue.png") as «class PNGf»)']); time.sleep(0.8)
    copy("after image")
    textedit_new("")
    key(9, "opt", "cmd"); time.sleep(0.4); dbg("key:down"); dbg("key:enter", 1.0)
    attach = osa('tell application "TextEdit" to count attachments of document 1') or osa('tell application "TextEdit" to get text of document 1')
    report(None, "image paste into TextEdit", f"attachments/text={attach!r}")
    screenshot("paste-image-textedit")

# ---------------------------------------------------------------- panel behaviour
if not sections or "panel" in sections:
    textedit_new("")
    key(9, "opt", "cmd"); time.sleep(0.4)
    before = dump()["count"]; copy("copied while panel open"); time.sleep(0.4); d = dump()
    report(d["panelVisible"] and d["count"] == before + 1 and d["previews"][0] == "copied while panel open",
           "copy while panel open updates list", f"count {before}->{d['count']} visible={d['panelVisible']}")
    screenshot("panel-live-update")
    key(53); time.sleep(0.3)
    # click outside closes, focus stays in TextEdit
    key(9, "opt", "cmd"); time.sleep(0.4)
    osa('tell application "Finder" to activate'); time.sleep(0.6)   # switching apps must close the panel
    d = dump(); report(not d["panelVisible"], "panel hides when another app takes focus", f"visible={d['panelVisible']} front={d['frontmost']}")
    # type-to-search goes to search field without clicking (TextEdit must already be frontmost, no new windows)
    front("TextEdit"); key(9, "opt", "cmd"); time.sleep(0.5)
    osa('tell application "System Events" to keystroke "while"'); time.sleep(0.3); d = dump()
    report(d["query"] == "while", "type-to-search", f"query={d['query']!r}")
    key(53); key(53); time.sleep(0.3)

# ---------------------------------------------------------------- full screen
if not sections or "fullscreen" in sections:
    def fs(proc, on):
        osa(f'tell application "System Events" to tell process "{proc}" to set value of attribute "AXFullScreen" of window 1 to {str(on).lower()}')
    for proc, opener in [("Preview", ["open", "-a", "Preview", f"{data_dir}/../blue.png"]),
                         ("TextEdit", None)]:
        if opener: subprocess.run(opener); time.sleep(2)
        else: textedit_new("")
        front(proc); fs(proc, True); time.sleep(2.5)
        isfs = osa(f'tell application "System Events" to tell process "{proc}" to get value of attribute "AXFullScreen" of window 1')
        key(9, "opt", "cmd"); time.sleep(0.6); d = dump()
        screenshot(f"fs-{proc.lower()}-panel")
        still = osa(f'tell application "System Events" to tell process "{proc}" to get value of attribute "AXFullScreen" of window 1')
        report(isfs == "true" and d["panelVisible"] and d["panelKey"] and still == "true",
               f"full-screen {proc}: panel over it, no Space switch", f"fs={isfs}->{still} visible={d['panelVisible']} key={d['panelKey']} front={d['frontmost']}")
        key(53); time.sleep(0.3); fs(proc, False); time.sleep(2)
    osa('tell application "System Events" to tell process "Preview" to click button 1 of window 1')

# ---------------------------------------------------------------- privacy
if not sections or "privacy" in sections:
    secret = "SuperSecret-Pa55w0rd-%d" % int(time.time())
    subprocess.run([sys.executable, "-c", f'''
from AppKit import NSPasteboard
pb=NSPasteboard.generalPasteboard(); pb.clearContents()
pb.declareTypes_owner_(["public.utf8-plain-text","org.nspasteboard.ConcealedType"],None)
pb.setString_forType_("{secret}","public.utf8-plain-text"); pb.setString_forType_("","org.nspasteboard.ConcealedType")'''])
    time.sleep(1.0)
    d = dump()
    hits = sh("grep", "-rl", secret, data_dir)
    logs = sh("/usr/bin/log", "show", "--last", "2m", "--info", "--predicate", 'subsystem == "app.clipboard-history"')
    report(secret not in json.dumps(d["previews"]) and not hits and secret not in logs,
           "concealed item never stored or logged", f"in list={secret in json.dumps(d['previews'])} files={hits or 'none'} in logs={secret in logs}")
    copy("plain marker text for log check")
    logs = sh("/usr/bin/log", "show", "--last", "1m", "--info", "--predicate", 'subsystem == "app.clipboard-history"')
    report("plain marker text" not in logs, "normal content not in system log", f"log lines={len(logs.splitlines())}")
    marker = "zqxmarker%d" % int(time.time())
    copy(f"spotlight probe {marker}"); key(9, "opt", "cmd"); time.sleep(0.6); key(53); time.sleep(20)
    found = sh("mdfind", marker)
    report(not found, "clipboard text not indexed by Spotlight (20 s after showing it)", f"mdfind hits={found or 'none'}")
    perms = sh("stat", "-f", "%Sp %N", f"{data_dir}/history.sqlite", f"{data_dir}/blobs")
    report("rw-------" in perms and "drwx------" in perms, "data file permissions", perms.replace("\n", " | "))
    sharing = dump()
    report(None, "pause toggle", "covered by unit test PrivacyTests.testExcludedAppAndPause")

print("\nSUMMARY", sum(r.startswith("PASS") for r in results), "pass,",
      sum(r.startswith("FAIL") for r in results), "fail,", sum(r.startswith("INFO") for r in results), "info")
