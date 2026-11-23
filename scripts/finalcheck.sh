#!/bin/zsh
# Remaining on-screen checks. Every synthetic key is sent ONLY if the expected app is frontmost (K <bundle> <key...>);
# otherwise the run aborts. Restores the user's shortcut and relaunches their Clipboard History on exit.
T=$1; ROOT="${0:A:h}/.."; D=$T/fc/data
idle() { echo $(( $(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}') / 1000000000 )); }
for i in {1..720}; do [ $(idle) -ge 120 ] && $T/locked >/dev/null && break; sleep 15; done
[ $(idle) -ge 120 ] || { echo "GAVE UP: user never idle"; exit 2; }
USER_SC=$(defaults read app.clipboard-history KeyboardShortcuts_openPanel)
restore() { pkill -x ClipboardHistory; sleep 0.5; defaults write app.clipboard-history KeyboardShortcuts_openPanel -string "$USER_SC"; defaults delete app.clipboard-history hideFromCapture 2>/dev/null; open "$ROOT/build/ClipboardHistory.app"; }
trap restore EXIT
front() { lsappinfo info -only bundleid $(lsappinfo front) | sed -nE 's/.*"(.*)".*/\1/p'; }
K() { local want=$1; shift; $T/locked >/dev/null || { echo "ABORT locked"; exit 3; }
      [ $(idle) -ge 5 ] || { echo "ABORT user active"; exit 5; }
      local f=$(front); [ "$f" = "$want" ] || { echo "ABORT expected $want frontmost, got $f"; exit 4; }; $T/key "$@"; }
dump() { "$ROOT/scripts/dbg.sh" dump; sleep 0.5; }
J() { python3 -c "import json;d=json.load(open('$D/debug-state.json'));print($1)"; }
fsset() { osascript -e "tell application \"System Events\" to tell process \"$1\" to set value of attribute \"AXFullScreen\" of window 1 to $2"; sleep 2.5; }
fsget() { osascript -e "tell application \"System Events\" to tell process \"$1\" to get value of attribute \"AXFullScreen\" of window 1"; }
rm -rf "${D:?}"; mkdir -p $D; pkill -x ClipboardHistory; sleep 0.5
defaults write app.clipboard-history KeyboardShortcuts_openPanel -string '{"carbonModifiers":2304,"carbonKeyCode":9}'
defaults write app.clipboard-history hideFromCapture -bool false
open -n --env CLIPBOARD_HISTORY_DATA_DIR=$D --env CLIPBOARD_HISTORY_SKIP_ONBOARDING=1 "$ROOT/build/ClipboardHistory.app"; sleep 2.5
dump; J "'test hotkey:', d['hotkey']"
echo "== full screen"
for app in TextEdit Preview; do
  if [ $app = Preview ]; then open -a Preview "$T/persona/photo.png"; else open -a TextEdit; sleep 0.6; osascript -e 'tell application "TextEdit" to make new document' >/dev/null; fi
  sleep 1.5; bid=com.apple.$app; fsset $app true; echo "$app fullscreen: $(fsget $app)"
  K $bid 9 opt cmd; sleep 0.6; dump; J "'  panel visible',d['panelVisible'],'key',d['panelKey'],'front',d['frontmost']"
  screencapture -x "$ROOT/usertest/fc-fs-$app.png"; echo "  still fullscreen: $(fsget $app)"
  K $bid 53; sleep 0.3; fsset $app false
done
osascript -e 'tell application "TextEdit" to close every document saving no'
echo "== VS Code caret fallback"
open -a "Visual Studio Code"; sleep 3; K com.microsoft.VSCode 45 cmd; sleep 1.5
osascript -e 'tell application "System Events" to tell process "Code" to get {position, size} of window 1'
K com.microsoft.VSCode 9 opt cmd; sleep 0.6; dump; J "'  visible',d['panelVisible'],'front',d['frontmost'],'caretMs',round(d['lastCaretMs'],1)"
"$T/sbwins" | grep "layer 3"
screencapture -x "$ROOT/usertest/fc-vscode.png"; K com.microsoft.VSCode 53; sleep 0.3
echo "== multi-file drag"
mkdir -p $T/fc/files; for n in a b c; do echo "$n" > $T/fc/files/$n.txt; done
osascript -e "set the clipboard to {POSIX file \"$T/fc/files/a.txt\", POSIX file \"$T/fc/files/b.txt\", POSIX file \"$T/fc/files/c.txt\"}" >/dev/null; sleep 1.2
dump; J "'  top item:',d['kinds'][:1],d['previews'][:1]"
open -a TextEdit; sleep 0.6; osascript -e 'tell application "TextEdit" to make new document' >/dev/null; sleep 0.8
K com.apple.TextEdit 9 opt cmd; sleep 0.6
ROW=$("$T/axdump" $(pgrep -x ClipboardHistory) 200 | grep "AXButton | Files" | head -1); echo "  row: $(echo $ROW | cut -c1-70)"
RX=$(echo "$ROW" | sed -E 's/.*@([0-9]+),([0-9]+) ([0-9]+)x([0-9]+).*/\1/'); RY=$(echo "$ROW" | sed -E 's/.*@([0-9]+),([0-9]+).*/\2/')
read WX WY WW WH <<< $(osascript -e 'tell application "System Events" to tell process "TextEdit" to get {position, size} of window 1' | tr -d ',')
if [ -n "$RX" ] && [ "$(front)" = com.apple.TextEdit ]; then $T/mouse drag $((RX+120)) $((RY+23)) $((WX+WW-120)) $((WY+WH-100)); sleep 1.5; fi
echo "  attachments after drop: $(osascript -e 'tell application "TextEdit" to count attachments of document 1')"
screencapture -x "$ROOT/usertest/fc-multidrag.png"; osascript -e 'tell application "TextEdit" to close every document saving no'
echo "== reduce motion"
pkill -x ClipboardHistory; sleep 0.5; open -n --env CLIPBOARD_HISTORY_DATA_DIR=$D --env CLIPBOARD_HISTORY_SKIP_ONBOARDING=1 --env CLIPBOARD_HISTORY_REDUCE_MOTION=1 "$ROOT/build/ClipboardHistory.app"; sleep 2.5
open -a TextEdit; sleep 0.8; K com.apple.TextEdit 9 opt cmd; dump; J "'  reduce motion: animated',d['lastShowAnimated'],'alpha',d['panelAlpha']"; K com.apple.TextEdit 53
pkill -x ClipboardHistory; sleep 0.5; open -n --env CLIPBOARD_HISTORY_DATA_DIR=$D --env CLIPBOARD_HISTORY_SKIP_ONBOARDING=1 "$ROOT/build/ClipboardHistory.app"; sleep 2.5
open -a TextEdit; sleep 0.8; K com.apple.TextEdit 9 opt cmd; dump; J "'  normal: animated',d['lastShowAnimated']"; K com.apple.TextEdit 53
echo DONE
