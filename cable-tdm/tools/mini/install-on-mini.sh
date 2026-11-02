#!/bin/bash
# install-on-mini.sh — runs ON the Mac mini (copied there by install-display-off.sh).
# ONE app (Screen Off.app in ~/Applications + Dock), one LaunchAgent keeping the display awake.
set -u
APP="$HOME/Applications/Screen Off.app"
LABEL=com.imac-tdm.keep-display-awake
PL="$HOME/Library/LaunchAgents/$LABEL.plist"
UIDN=$(id -u)

chmod 755 ~/od-sender/display-off.sh
mkdir -p ~/Applications ~/Library/LaunchAgents
rm -rf "$HOME/Applications/Display Off.app" "$APP"
/usr/bin/osacompile -e 'do shell script "/usr/bin/pmset displaysleepnow"' -o "$APP"

cp ~/od-sender/keep-display-awake.plist "$PL"
launchctl bootout "gui/$UIDN/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UIDN" "$PL"
sleep 1
pkill -f 'caffeinate -d -i -s -u' 2>/dev/null || true   # the ad-hoc hold from the ssh session

if ! defaults read com.apple.dock persistent-apps 2>/dev/null | grep -qE 'Screen(%20| )Off.app'; then
  defaults write com.apple.dock persistent-apps -array-add \
    "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$APP</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
  killall Dock
fi

# Desktop copy through Finder (Finder owns ~/Desktop; ssh itself is TCC-denied). Non-fatal.
if osascript -e 'with timeout of 10 seconds' \
     -e "tell application \"Finder\" to duplicate (POSIX file \"$APP\" as alias) to desktop with replacing" \
     -e 'end timeout' >/dev/null 2>&1; then echo "DESKTOP ok"; else echo "DESKTOP skipped (TCC: allow sshd->Finder on the console, or drag the Dock icon)"; fi

echo "--- verify"
ls -d "$APP"
launchctl list | grep "$LABEL"
pmset -g assertions | grep -E 'PreventUserIdleDisplaySleep.*caffeinate' | head -1
pmset -g | grep -E '^ *(displaysleep|sleep) '
echo INSTALLED
