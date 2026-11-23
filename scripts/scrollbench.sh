#!/bin/zsh
# Throughput of ↓ handling: post N arrow presses at R/s from one process, time until selection == N.
# usage: scrollbench.sh <data_dir> <tools_dir> [N] [interval_s]
D=$1; T=$2; N=${3:-300}; I=${4:-0.005}
lsappinfo info -only bundleid $(lsappinfo front) | grep -qE "UserNotificationCenter|CoreServicesUIAgent|SecurityAgent" && { echo ABORT; exit 4; }
$T/locked >/dev/null || exit 3
"${0:A:h}/dbg.sh" toggle; sleep 0.6
start=$(python3 -c 'import time;print(time.time())')
$T/key 125 --repeat $N --interval $I
sent=$(python3 -c 'import time;print(time.time())')
for i in {1..200}; do
  "${0:A:h}/dbg.sh" dump; sleep 0.05
  sel=$(python3 -c "import json;d=json.load(open('$D/debug-state.json'));print(d['selection'] if d['panelVisible'] else -1)")
  [ "$sel" = "$N" -o "$sel" = "-1" ] && break
done
end=$(python3 -c 'import time;print(time.time())')
python3 -c "print('selection $sel  sent in %.2fs  caught up after %.2fs  => %.0f steps/s' % ($sent-$start, $end-$start, $N/($end-$start)))"
"${0:A:h}/dbg.sh" hide
