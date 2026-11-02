#!/bin/bash
# setup-sender.sh — run ON THE MAC MINI (M6, macOS 14+). Makes the iMac-display key the Mac mini's 2nd display
# over the one direct Ethernet cable.
#
#   ./setup-sender.sh                 install OpenDisplay sender, give the Ethernet port 10.10.10.1, wait for the
#                                     receiver (iMac = 10.10.10.2:9000), open the sender, print the display list
#   ./setup-sender.sh --dry-run       print every command instead of running it (no changes)
#   ./setup-sender.sh --service "Ethernet Adapter"   name of the network service that holds the cable
#   ./setup-sender.sh --wait 300      seconds to wait for the receiver (default 180)
#   Also installs the launch agent app.opendisplay.autoconnect (od-autoconnect.sh: keeps 10.10.10.1 + the sender open).
#
# Network: manual 10.10.10.1/24 with NO router on the cable service, so Wi-Fi keeps the default route (nothing is
# hijacked) while 10.10.10.0/24 is reachable on the cable. (Not "-setmanualwithdhcprouter": without a DHCP server
# that mode gave a /32 mask and no route to the receiver — Mac mini log 2026-11-01.)
# Discovery: the receiver advertises _opensidecar._tcp via mDNS on the link; the sender finds it by itself.
# Receiver side (iMac key): static 10.10.10.2/24, TCP 9000 + UDP 9001.
set -euo pipefail
DRY=0; SERVICE=""; WAIT_S=180; RECEIVER_IP=10.10.10.2; SENDER_IP=10.10.10.1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --service) SERVICE=${2:?}; shift ;;
    --wait)    WAIT_S=${2:?}; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac; shift
done
log() { printf '[sender %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
run() { if [ "$DRY" = 1 ]; then printf 'DRY: %s\n' "$*"; else log "+ $*"; "$@"; fi; }

# ---- 1 which service holds the cable --------------------------------------------------------------------
if [ -z "$SERVICE" ]; then
  SERVICE=$(networksetup -listallhardwareports 2>/dev/null | awk -F': ' '
      /^Hardware Port:/ {port=$2}
      /^Device:/ && port ~ /Ethernet|LAN|USB 10\/100\/1000|Thunderbolt Ethernet/ && !found {print port; found=1}')
  SERVICE=${SERVICE:-Ethernet}
fi
log "network service for the cable: \"$SERVICE\" (override with --service)"
run networksetup -getinfo "$SERVICE"

# ---- 2 sender app --------------------------------------------------------------------------------------
if [ -d /Applications/OpenDisplay.app ]; then
  log "OpenDisplay.app already installed"
elif command -v brew >/dev/null 2>&1; then
  run brew install --cask opendisplay
else
  DMG=/tmp/OpenDisplay.dmg
  run curl -fL -o "$DMG" https://github.com/peetzweg/opendisplay/releases/latest/download/OpenDisplay.dmg
  run hdiutil attach -nobrowse "$DMG"
  run cp -R "/Volumes/OpenDisplay/OpenDisplay.app" /Applications/
  run hdiutil detach /Volumes/OpenDisplay
fi

# ---- 3 address on the cable (no default-route hijack) -------------------------------------------------
# manual IP + /24 mask, NO router (3-arg form verified on macOS 15.8): "-setmanualwithdhcprouter" takes the mask from
# DHCP, and with no DHCP server on the direct cable it became /32 (Mac mini log 2026-11-01 04:43: netmask 0xffffffff),
# so 10.10.10.2 had no route and the receiver was "NOT reachable". No router = Wi-Fi keeps the default route.
run networksetup -setmanual "$SERVICE" "$SENDER_IP" 255.255.255.0
run networksetup -setv6off "$SERVICE"
run sleep 3
# exact port-name match + exit: Apple-silicon Macs also list "Ethernet Adapter (en4)" … slots; the old substring match
# printed 4 devices and ifconfig aborted the script right here (Mac mini log 2026-11-01 04:29, steps 4-6 never ran).
run ifconfig "$(networksetup -listallhardwareports | awk -v s="$SERVICE" -F': ' '$1=="Hardware Port" && $2==s {getline; print $2; exit}')"

# ---- 4 wait for the receiver -----------------------------------------------------------------------------
if [ "$DRY" = 1 ]; then
  printf 'DRY: until nc -z -G 2 %s 9000; do sleep 5; done   # <= %ss\n' "$RECEIVER_IP" "$WAIT_S"
  printf 'DRY: dns-sd -B _opensidecar._tcp local.          # Bonjour: iMac advertises itself\n'
else
  log "waiting up to ${WAIT_S}s for the receiver at $RECEIVER_IP:9000 (iMac booted from the key, cable in)"
  t0=$(date +%s); ok=0
  while [ $(( $(date +%s) - t0 )) -lt "$WAIT_S" ]; do
    if nc -z -G 2 "$RECEIVER_IP" 9000 2>/dev/null; then ok=1; break; fi
    sleep 5
  done
  [ "$ok" = 1 ] && log "receiver reachable on TCP 9000" || log "receiver NOT reachable yet — the sender will still find it via Bonjour when it comes up"
  (dns-sd -B _opensidecar._tcp local. > /tmp/od-bonjour.txt 2>&1 &) ; sleep 4; pkill -f 'dns-sd -B _opensidecar' || true
  grep -i -E 'imac|opensidecar' /tmp/od-bonjour.txt | tail -3 || true
fi

# ---- 5 open the sender, show the displays -------------------------------------------------------------------
run open -a OpenDisplay
run sleep 8
run system_profiler SPDisplaysDataType
log "in the OpenDisplay menu-bar app pick the receiver \"imac27\" (or dial $RECEIVER_IP), then Displays settings: arrange / 2560x1440"

# ---- 6 launch agent: keep the address and the sender alive across reboots / cable re-plugs -----------------------
# app.opendisplay.autoconnect = macmini/od-autoconnect.sh (5 s loop: re-assert 10.10.10.1, open OpenDisplay while the
# receiver answers, log "manual pick needed" once). The sender has no CLI/URL scheme, so the imac27 pick stays manual.
HERE=$(cd "$(dirname "$0")" && pwd)
AGENT_LABEL=app.opendisplay.autoconnect
AGENT_DIR="$HOME/Library/Application Support/od-autoconnect"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
if [ "$DRY" = 1 ]; then
  printf 'DRY: install -m 755 %s/od-autoconnect.sh "%s/"   # autoconnect launch agent, log ~/Library/Logs/od-autoconnect.log\n' "$HERE" "$AGENT_DIR"
  printf 'DRY: sed s|__HOME__|%s|g %s/od-autoconnect.plist > %s; plutil -replace EnvironmentVariables.OD_SERVICE -string "%s"\n' "$HOME" "$HERE" "$AGENT_PLIST" "$SERVICE"
  printf 'DRY: launchctl bootout gui/%s/%s; launchctl bootstrap gui/%s %s; launchctl kickstart -k gui/%s/%s\n' "$UID" "$AGENT_LABEL" "$UID" "$AGENT_PLIST" "$UID" "$AGENT_LABEL"
else
  [ -s "$HERE/od-autoconnect.sh" ] && [ -s "$HERE/od-autoconnect.plist" ] || { echo "ERROR: od-autoconnect.sh / od-autoconnect.plist missing next to $0" >&2; exit 1; }
  mkdir -p "$AGENT_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  install -m 755 "$HERE/od-autoconnect.sh" "$AGENT_DIR/od-autoconnect.sh"
  sed "s|__HOME__|$HOME|g" "$HERE/od-autoconnect.plist" > "$AGENT_PLIST"
  plutil -replace EnvironmentVariables.OD_SERVICE -string "$SERVICE" "$AGENT_PLIST"
  plutil -lint "$AGENT_PLIST" >/dev/null
  launchctl bootout "gui/$UID/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID" "$AGENT_PLIST"
  launchctl kickstart -k "gui/$UID/$AGENT_LABEL"
  sleep 2; tail -3 "$HOME/Library/Logs/od-autoconnect.log" 2>/dev/null || true
  log "launch agent $AGENT_LABEL installed: keeps $SENDER_IP on \"$SERVICE\" and OpenDisplay open; log ~/Library/Logs/od-autoconnect.log"
fi
