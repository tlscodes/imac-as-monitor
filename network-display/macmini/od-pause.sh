#!/bin/bash
# od-pause.sh — park the OpenDisplay sender on the Mac mini for the direct-cable (TDM) test.
#   pause   : back up app + prefs + launch agent to ~/od-backup/<stamp>/, stop the agent, quit the app
#   resume  : re-enable the agent and relaunch the app (fast rollback, nothing reinstalled)
#   status  : show what is running
# Runs ON the Mac mini (no sudo, no reboot, no uninstall). Backups are never deleted.
set -u
APP=/Applications/OpenDisplay.app
DOM=com.peetzweg.opensidecar.mac
AGENT=app.opendisplay.autoconnect
PLIST="$HOME/Library/LaunchAgents/$AGENT.plist"
PAUSE="$HOME/.od-autoconnect-pause"
UID_=$(id -u)
status() {
  printf 'app running : %s\n' "$(pgrep -x OpenDisplay >/dev/null && echo yes || echo no)"
  printf 'agent loaded: %s\n' "$(launchctl print "gui/$UID_/$AGENT" >/dev/null 2>&1 && echo yes || echo no)"
  printf 'pause file  : %s\n' "$([ -e "$PAUSE" ] && echo present || echo absent)"
  printf 'stream      : %s\n' "$(netstat -an 2>/dev/null | grep -c '10.10.10.2.9000.*ESTABLISHED')"
}
case "${1:-status}" in
  pause)
    [ -d "$APP" ] || { echo "no $APP"; exit 1; }
    B="$HOME/od-backup/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$B"
    ditto "$APP" "$B/OpenDisplay.app" && echo "backup app   -> $B/OpenDisplay.app"
    defaults export "$DOM" "$B/prefs.plist" 2>/dev/null && echo "backup prefs -> $B/prefs.plist"
    [ -f "$PLIST" ] && cp "$PLIST" "$B/" && echo "backup agent -> $B/$AGENT.plist"
    [ -d "$HOME/Library/Application Support/OpenDisplay" ] && ditto "$HOME/Library/Application Support/OpenDisplay" "$B/AppSupport-OpenDisplay"
    touch "$PAUSE"
    launchctl bootout "gui/$UID_/$AGENT" 2>/dev/null
    osascript -e 'tell application "OpenDisplay" to quit' 2>/dev/null; sleep 2
    pgrep -x OpenDisplay >/dev/null && pkill -x OpenDisplay; sleep 1
    echo "$B" > "$HOME/od-backup/LAST"
    echo "--- paused"; status ;;
  resume)
    rm -f "$PAUSE"
    [ -f "$PLIST" ] && launchctl bootstrap "gui/$UID_" "$PLIST" 2>/dev/null
    open -a OpenDisplay
    sleep 3; echo "--- resumed"; status ;;
  status) status ;;
  *) echo "usage: od-pause.sh pause|resume|status"; exit 2 ;;
esac
