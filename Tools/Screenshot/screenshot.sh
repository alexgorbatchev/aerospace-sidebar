#!/usr/bin/env bash
# Captures the sidebar showing the demo cards in docs/screenshot/ (`just screenshot`). The running sidebar is quit
# for the capture and opened again afterwards; the demo touches neither its socket nor its saved state.
set -euo pipefail

app=".build/AerospaceSidebar.app"
demo="$PWD/docs/screenshot"
output="${1:-$demo/sidebar.png}"
helper=".build/screenshot-helper"

swiftc -swift-version 6 -O -o "$helper" Tools/Screenshot/main.swift

# Waits up to $2 seconds for process $1 to exit.
wait_for_exit() {
  for _ in $(seq $(($2 * 10))); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

running_app=""
if running_pid="$(pgrep -x AerospaceSidebar | head -n 1)"; then
  running_app="$(ps -o comm= -p "$running_pid" | sed 's|/Contents/MacOS/AerospaceSidebar$||')"
  echo "Quitting the running sidebar ($running_app) for the capture"
  "$helper" quit "$running_pid"
  wait_for_exit "$running_pid" 10 || { echo "The running sidebar did not quit" >&2; exit 1; }
fi

restore() {
  if [ -n "${demo_pid:-}" ]; then
    "$helper" quit "$demo_pid" 2>/dev/null || true
    wait_for_exit "$demo_pid" 10 || true
  fi
  if [ -n "$running_app" ]; then
    echo "Opening $running_app again"
    open "$running_app"
  fi
}
trap restore EXIT

open -n -g "$app" --args --demo "$demo"
for _ in $(seq 100); do
  demo_pid="$(pgrep -nx AerospaceSidebar || true)"
  [ -n "$demo_pid" ] && break
  sleep 0.1
done
[ -n "${demo_pid:-}" ] || { echo "The demo did not start" >&2; exit 1; }

window=""
for _ in $(seq 100); do
  window="$("$helper" window "$demo_pid" || true)"
  [ -n "$window" ] && break
  sleep 0.1
done
[ -n "$window" ] || { echo "The demo's panel never showed (is the screen locked?)" >&2; exit 1; }

# Let the launch reveal finish.
sleep 2
screencapture -o -x -l "$window" "$output"
"$helper" crop "$output"
echo "Saved $output"
