#!/bin/bash
# od-autoconnect.sh — launch agent on the Mac mini (app.opendisplay.autoconnect, installed by setup-sender.sh).
# Every 5 s: keep 10.10.10.1 on the Ethernet service that holds the cable, and while the iMac receiver
# (10.10.10.2:9000) answers keep the OpenDisplay sender open AND streaming — zero clicks:
#   * the sender auto-connects to its remembered receiver (pref wifiRemembered = "wifi:imac27") when it is
#     LAUNCHED (proven 2026-11-01: 05:46:38 open -a -> 05:46:44 ESTABLISHED, nobody clicked). There is no CLI /
#     URL scheme to connect a running sender, so "receiver up + app running + no session for 30 s" (iMac rebooted,
#     cable re-plugged, sender gave up) is cured by a relaunch: SIGTERM (an AppleScript quit sent from a launch
#     agent needs a TCC Automation consent nobody can click here), SIGKILL after 5 s, open -a again. At most once
#     a minute; after 3 relaunches in a row without reaching streaming, once per 5 min. Streaming resets the count.
#   * touch ~/.od-autoconnect-pause while testing by hand: no open/relaunch, the IP keeper stays on.
#   * while a session is ESTABLISHED the receiver is not probed (nc -z) at all.
#
#   od-autoconnect.sh            loop forever (what the launch agent runs)
#   od-autoconnect.sh --once     one tick, then exit (self-test)
#
# env: OD_SERVICE (network service name; auto-detected when empty), OD_RECEIVER_IP, OD_SENDER_IP, OD_PORT,
#      OD_LOG (default ~/Library/Logs/od-autoconnect.log), OD_TICK (seconds, default 5),
#      OD_NOSESSION_S (seconds without a session before a relaunch, default 30), OD_PAUSE_FILE
set -u
SERVICE=${OD_SERVICE:-}; RECEIVER_IP=${OD_RECEIVER_IP:-10.10.10.2}; SENDER_IP=${OD_SENDER_IP:-10.10.10.1}
PORT=${OD_PORT:-9000}; TICK=${OD_TICK:-5}; LOG=${OD_LOG:-$HOME/Library/Logs/od-autoconnect.log}; ONCE=0
NOSESSION_S=${OD_NOSESSION_S:-15}; PAUSE_FILE=${OD_PAUSE_FILE:-$HOME/.od-autoconnect-pause}
STALE_TICKS=${OD_STALE_TICKS:-6}; STALE_BYTES=${OD_STALE_BYTES:-1500}; ACTIVE_S=${OD_ACTIVE_S:-8}
KEEP_AWAKE=${OD_KEEP_AWAKE:-1}; MAX_LOG_KB=${OD_MAX_LOG_KB:-1024}
APP_PAT='OpenDisplay.app/Contents/MacOS'
case "${1:-}" in --once) ONCE=1 ;; --status) ONCE=2 ;; esac
mkdir -p "$(dirname "$LOG")"
log() { printf '[od-autoconnect %s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
app_running() { pgrep -f "$APP_PAT" >/dev/null 2>&1; }
session_up() { netstat -an 2>/dev/null | grep -q "$RECEIVER_IP\.$PORT .*ESTABLISHED"; }
open_app() { open -a OpenDisplay >>"$LOG" 2>&1; }
relaunch_app() {                      # header: SIGTERM, SIGKILL after 5 s, then open -a (= auto-connect)
  pkill -TERM -f "$APP_PAT" 2>/dev/null
  local i=0; while app_running && [ "$i" -lt 5 ]; do sleep 1; i=$((i + 1)); done
  app_running && { pkill -KILL -f "$APP_PAT" 2>/dev/null; sleep 1; }
  open_app
}
# --- liveness signals (all user-level, no sudo, no TCC) ---------------------------------------------------------
# display_on: powerd holds "Prevent sleep while display is on" exactly while the (virtual) display is lit; it was
#   released at 17:57:49 on 2026-11-01 = the "frozen picture" the owner saw (display sleep after 10 idle min,
#   sender stops encoding, receiver keeps the last frame, wake lands on the lock screen). IODisplayWrangler does
#   not exist on Apple silicon, so this assertion is the only cheap probe.
display_on() { pmset -g assertions 2>/dev/null | grep -q 'Prevent sleep while display is on'; }
idle_s() { ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'; }
cable_dev() { networksetup -listallhardwareports 2>/dev/null | awk -F': ' -v p="$SERVICE" '$0 ~ "^Hardware Port: "p"$" {f=1} f && /^Device:/ {print $2; exit}'; }
obytes() { netstat -I "$CABLE_DEV" -b 2>/dev/null | awk 'NR==2 {print $10; exit}'; }
wake_display() { caffeinate -u -t 2 >/dev/null 2>&1; }
keep_awake() {                        # one caffeinate child for the agent's lifetime: display + idle sleep blocked
  [ "$KEEP_AWAKE" = 1 ] || return 0   # -w $$: caffeinate exits by itself when this agent dies, even on SIGKILL (no orphans)
  if [ -z "${KA_PID:-}" ] || ! kill -0 "$KA_PID" 2>/dev/null; then
    caffeinate -d -i -s -w $$ >/dev/null 2>&1 & KA_PID=$!
    log "keep-awake: caffeinate -d -i -s -w $$ pid $KA_PID (display sleep + idle sleep blocked while this agent runs)"
  fi
}
# rotate IN PLACE (truncate + rewrite): launchd holds the log open as StandardOutPath; an mv would leave it writing to an
# unlinked inode and `open -a` output would vanish.
rotate_log() { [ -f "$LOG" ] && [ "$(du -k "$LOG" | cut -f1)" -gt "$MAX_LOG_KB" ] && { tail -n 400 "$LOG" > "$LOG.tmp" && cat "$LOG.tmp" > "$LOG" && rm -f "$LOG.tmp"; log "log rotated in place (> ${MAX_LOG_KB} KB)"; }; return 0; }
trap '[ -n "${KA_PID:-}" ] && kill "$KA_PID" 2>/dev/null; exit 0' EXIT INT TERM

if [ -z "$SERVICE" ]; then
  SERVICE=$(networksetup -listallhardwareports 2>/dev/null | awk -F': ' '
      /^Hardware Port:/ {port=$2}
      /^Device:/ && port ~ /Ethernet|LAN|USB 10\/100\/1000|Thunderbolt Ethernet/ && !found {print port; found=1}')
  SERVICE=${SERVICE:-Ethernet}
fi
CABLE_DEV=$(cable_dev); CABLE_DEV=${CABLE_DEV:-en0}

if [ "$ONCE" = 2 ]; then              # --status: one health line for the owner / the acceptance log
  s=down; session_up && s=ESTABLISHED; d=off; display_on && d=on
  b0=$(obytes); sleep 2; b1=$(obytes)
  printf 'session=%s display=%s idle=%ss bytes/2s=%s app=%s receiver_port=%s service="%s" dev=%s\n' \
    "$s" "$d" "$(idle_s)" "$(( ${b1:-0} - ${b0:-0} ))" "$(app_running && echo running || echo stopped)" \
    "$(nc -z -G 2 "$RECEIVER_IP" "$PORT" 2>/dev/null && echo open || echo closed)" "$SERVICE" "$CABLE_DEV"
  exit 0
fi

log "start: service \"$SERVICE\" ($CABLE_DEV) sender $SENDER_IP receiver $RECEIVER_IP:$PORT tick ${TICK}s nosession ${NOSESSION_S}s stale ${STALE_TICKS}x<${STALE_BYTES}B"
# screen saver off for this user (another "stale picture" source); display sleep 0 needs an admin password:
#   sudo pmset -a displaysleep 0  — tried once without a password, logged either way.
defaults -currentHost write com.apple.screensaver idleTime -int 0 2>/dev/null || true
if sudo -n pmset -a displaysleep 0 2>/dev/null; then log "pmset displaysleep 0 set"; else log "pmset displaysleep stays $(pmset -g 2>/dev/null | awk '/displaysleep/ {print $2}') min (no passwordless sudo) — caffeinate covers it"; fi

state=""; last_ip_fix=0; last_open=0; nosession_since=0; relaunches=0; stale=0; prev_bytes=""; last_wake=0
while :; do
  now=$(date +%s); rotate_log; keep_awake

  # 1 address on the cable — re-asserted at most once a minute (a Wi-Fi/DHCP change or a reboot can drop it).
  #   Manual IP + /24 mask + NO router (Wi-Fi keeps the default route). The mask is checked too: the old
  #   "-setmanualwithdhcprouter" left a /32 mask without a DHCP server (no route to the receiver, 2026-11-01).
  if [ "$(networksetup -getinfo "$SERVICE" 2>/dev/null | grep -cE "^(IP address: $SENDER_IP|Subnet mask: 255\.255\.255\.0)\$")" != 2 ]; then
    if [ $((now - last_ip_fix)) -ge 60 ]; then
      if networksetup -setmanual "$SERVICE" "$SENDER_IP" 255.255.255.0 >>"$LOG" 2>&1; then
        log "set \"$SERVICE\" to $SENDER_IP/24, no router (Wi-Fi keeps the default route)"
      else
        log "networksetup -setmanual rc=$? — run setup-sender.sh once from an admin account"
      fi
      last_ip_fix=$now
    fi
  fi

  # 2 session established?  else: receiver reachable?  sender running?  (netstat first: no probe while streaming)
  if session_up; then
    new=streaming; nosession_since=0
    # 2a display asleep while a session exists = frozen picture on the iMac: wake it (at most every 20 s).
    #    At most 3 wakes per dark episode: an owner who locks the screen on purpose (Ctrl+Cmd+Q, hot corner) is not
    #    fought forever; idle sleep itself is already blocked by keep_awake, so a 4th dark tick is intent, logged once.
    if ! display_on; then
      if [ "${wakes:-0}" -lt 3 ]; then
        if [ $((now - last_wake)) -ge 20 ]; then wake_display; last_wake=$now; wakes=$((${wakes:-0} + 1)); log "display off while streaming -> woke it (caffeinate -u, $wakes/3 this episode)"; fi
      elif [ "${wakes:-0}" = 3 ]; then
        wakes=4; log "display still off after 3 wakes -> treating it as the owner's lock/sleep; no more wakes until it is on again"
      fi
      stale=0
    else
      wakes=0
      # 2b stale session: the owner is active (HID idle < ACTIVE_S) yet the cable carries < STALE_BYTES per tick
      #    for STALE_TICKS ticks in a row = TCP alive, no frames (seen 17:57 on 2026-11-01: 730 B/4 s ESTABLISHED).
      #    A static desktop with nobody touching the Mac mini never trips it (idle grows past ACTIVE_S).
      cur=$(obytes); idle=$(idle_s)
      if [ -n "$prev_bytes" ] && [ -n "$cur" ] && [ "${idle:-999}" -lt "$ACTIVE_S" ] && [ $((cur - prev_bytes)) -lt "$STALE_BYTES" ]; then
        stale=$((stale + 1))
      else
        stale=0                       # frames flow again (or the owner stepped away); relaunch history resets after 60 s streaming below
      fi
      prev_bytes=$cur
      if [ "$stale" -ge "$STALE_TICKS" ] && [ ! -e "$PAUSE_FILE" ]; then
        gap=20; [ "$relaunches" -ge 3 ] && gap=120
        if [ $((now - last_open)) -ge "$gap" ]; then
          relaunches=$((relaunches + 1)); stale=0
          log "stale session: owner active (idle ${idle}s) but < ${STALE_BYTES} B/tick for ${STALE_TICKS} ticks -> relaunch #$relaunches"
          if relaunch_app; then log "relaunched OpenDisplay (stale)"; else log "open -a OpenDisplay rc=$? after the kill"; fi
          last_open=$now
        fi
      fi
    fi
  elif nc -z -G 2 "$RECEIVER_IP" "$PORT" 2>/dev/null; then
    new=receiver-up; stale=0; prev_bytes=""
    [ "$nosession_since" = 0 ] && nosession_since=$now
    if [ -e "$PAUSE_FILE" ]; then
      [ "$new" = "$state" ] || log "paused by $PAUSE_FILE: no open/relaunch until it is removed"
    elif ! app_running; then
      if [ $((now - last_open)) -ge 20 ]; then
        if open_app; then log "opened OpenDisplay (it auto-connects to the remembered receiver)"; else log "open -a OpenDisplay rc=$? — not installed? run setup-sender.sh"; fi
        last_open=$now
      fi
    elif [ $((now - nosession_since)) -ge "$NOSESSION_S" ]; then
      # backoff 20 s, 40 s, 60 s, then 300 s between relaunches; a session that lasts resets the count (below)
      case "$relaunches" in 0) gap=20 ;; 1) gap=40 ;; 2) gap=60 ;; *) gap=300 ;; esac
      if [ $((now - last_open)) -ge "$gap" ]; then
        relaunches=$((relaunches + 1))
        log "receiver up, app running, no session for $((now - nosession_since)) s -> relaunch #$relaunches (next in >= $gap s; touch $PAUSE_FILE to stop)"
        if relaunch_app; then log "relaunched OpenDisplay"; else log "open -a OpenDisplay rc=$? after the kill"; fi
        last_open=$now
      fi
    fi
  else
    new=receiver-down; nosession_since=0; stale=0; prev_bytes=""
  fi
  # a session that has lived 60 s counts as a good connection: forget the relaunch history
  if [ "$new" = streaming ]; then
    [ "${streaming_since:-0}" = 0 ] && streaming_since=$now
    [ $((now - streaming_since)) -ge 60 ] && relaunches=0
  else
    streaming_since=0
  fi

  [ "$new" = "$state" ] || { log "state: ${state:-init} -> $new"; state=$new; }
  [ "$ONCE" = 1 ] && exit 0
  sleep "$TICK"
done
