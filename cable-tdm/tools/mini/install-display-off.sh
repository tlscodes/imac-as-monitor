#!/bin/bash
# install-display-off.sh — run from THIS Mac. Installs on the Mac mini (no sudo needed):
#   ~/od-sender/display-off.sh                       CLI / ssh:  screen off now
#   ~/Applications/Screen Off.app  (+ Dock icon)      one click: screen off now, any mouse move = back
#   ~/Library/LaunchAgents/com.imac-tdm.keep-display-awake.plist
#       holds `caffeinate -d -i -s` forever -> the mini never idle-sleeps its display or itself,
#       so the DisplayPort link to the iMac (Target Display Mode) never drops on its own.
# The old "Display Off.app" is removed: ONE app, ONE job. Idempotent.
# Desktop copy: ~/Desktop is TCC-protected over ssh; it is tried through Finder (10 s) and
# otherwise skipped — the Dock icon is the reliable button.
set -eu
HOST="${1:-user@mac-mini.local}"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$HOME/.ssh/cm/%r@%h:%p" -o ControlPersist=30m -o ConnectTimeout=10 "$HOST")
HERE="$(cd "$(dirname "$0")" && pwd)"
scp -o ControlPath="$HOME/.ssh/cm/%r@%h:%p" "$HERE/display-off.sh" "$HERE/keep-display-awake.plist" "$HERE/install-on-mini.sh" "$HOST:od-sender/"
"${SSH[@]}" 'bash ~/od-sender/install-on-mini.sh'
