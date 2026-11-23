#!/bin/zsh
# Exit 0 only if nobody touched the keyboard/mouse for the last $1 seconds (default 40), after waiting for it.
need=${1:-40}
sleep $((need + 3))
idle=$(( $(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print $NF; exit}') / 1000000000 ))
[ $idle -ge $need ] && exit 0 || { echo "USER ACTIVE (idle ${idle}s) — stopping GUI work"; exit 1; }
