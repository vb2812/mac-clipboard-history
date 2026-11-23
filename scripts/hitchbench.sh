#!/bin/zsh
# Records Animation Hitches while arrowing down 180 rows at 30/s (fastest macOS key repeat). usage: hitchbench.sh <app> <data_dir> <tools_dir> <out.trace>
APP=$1; D=$2; T=$3; OUT=$4
pkill -x ClipboardHistory; sleep 0.5; rm -rf "$OUT"
open -n --env CLIPBOARD_HISTORY_DATA_DIR=$D --env CLIPBOARD_HISTORY_SKIP_ONBOARDING=1 "$APP"; sleep 2.5; open -a TextEdit; sleep 0.8
lsappinfo info -only bundleid $(lsappinfo front) | grep -qE "UserNotificationCenter|CoreServicesUIAgent|SecurityAgent" && { echo ABORT; exit 4; }
$T/locked >/dev/null || exit 3
"${0:A:h}/dbg.sh" toggle; sleep 0.6
xcrun xctrace record --template 'Animation Hitches' --attach $(pgrep -x ClipboardHistory) --time-limit 9s --output "$OUT" >/dev/null 2>&1 &
sleep 2; $T/key 125 --repeat 180 --interval 0.028; wait
"${0:A:h}/dbg.sh" hide
rm -f $TMPDIR/instruments*.ktrace 2>/dev/null
