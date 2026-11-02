#!/bin/bash
# install-display-off.sh — run from THIS Mac. Installs on the Mac mini:
#   ~/od-sender/display-off.sh          (CLI / ssh)
#   ~/Applications/Display Off.app      (one click in Finder, Dock or Spotlight)
# Idempotent: re-running overwrites both. Nothing else on the mini is touched.
set -eu
HOST="${1:-user@mac-mini.local}"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$HOME/.ssh/cm/%r@%h:%p" -o ControlPersist=30m -o ConnectTimeout=10 "$HOST")
HERE="$(cd "$(dirname "$0")" && pwd)"
scp -o ControlPath="$HOME/.ssh/cm/%r@%h:%p" "$HERE/display-off.sh" "$HOST:od-sender/display-off.sh"
"${SSH[@]}" 'chmod 755 ~/od-sender/display-off.sh && mkdir -p ~/Applications && rm -rf "$HOME/Applications/Display Off.app" && /usr/bin/osacompile -e "do shell script \"/usr/bin/pmset displaysleepnow\"" -o "$HOME/Applications/Display Off.app" && ls -d "$HOME/Applications/Display Off.app" ~/od-sender/display-off.sh && echo INSTALLED'
