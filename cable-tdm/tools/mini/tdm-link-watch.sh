#!/bin/bash
# tdm-link-watch.sh — LaunchAgent com.imac-tdm.link-watch on the Mac mini (no sudo).
#
# Why: after a Mac mini reboot (or any DP drop) the mini sees the iMac as "No Link"
# (ioreg LinkRateDescription) and nothing on the mini repairs it; the iMac's tdm-guard
# cannot see it (MVHR stays 1). The proven fix is TDM off, 3 s, on ON THE IMAC.
# The iMac key runs tdm-kickd (eth0 10.10.10.2, TCP 9100) on the spare Ethernet cable;
# this watcher asks it for that kick. Verified 2026-11-03: the link stays "2.7 Gbps (HBR)"
# while the mini display sleeps, so "No Link" really means a dead link, never screen-off.
#
#   every POLL s: read the link. NEED consecutive bad readings -> KICK, then wait
#   BACKOFF s before the next one (30, 60, 300, 300 ...; resets when the link is back).
#   bad = "No Link" or no DP sink at all (iMac off / cable out) — the kick is then harmless.
# Manual:  ~/od-sender/tdm-link-watch.sh kick     one KICK now
#          ~/od-sender/tdm-link-watch.sh status   one line
# Log: ~/Library/Logs/tdm-link-watch.log
HOST=${TDM_KEY_HOST:-10.10.10.2}
PORT=${TDM_KEY_PORT:-9100}
MYIP=${TDM_MINI_IP:-10.10.10.1}
POLL=${TDM_POLL:-10}
NEED=${TDM_NEED:-2}
LOG="$HOME/Library/Logs/tdm-link-watch.log"
mkdir -p "$(dirname "$LOG")"

log()  { echo "$(date '+%F %T') $*" >> "$LOG"; }
link() { ioreg -lw0 2>/dev/null | sed -n 's/.*"LinkRateDescription" = "\(.*\)".*/\1/p' | head -1; }
# Apple's nc has no -N (it means something else there and errors out); -G = connect timeout,
# -w = idle timeout, so the connection closes 3 s after the line is sent and kickd reads EOF.
kick() { printf 'KICK\n' | /usr/bin/nc -G 3 -w 3 "$HOST" "$PORT" 2>&1; }
good() { case "$1" in ""|"No Link") return 1 ;; *) return 0 ;; esac; }

case "${1:-}" in
    kick)   out=$(kick); rc=$?; log "manual KICK rc=$rc $out"; echo "KICK sent rc=$rc $out"; exit $rc ;;
    status) l=$(link); echo "link: ${l:-none}  en0: $(ifconfig en0 2>/dev/null | awk '/status:/{print $2}') $(ifconfig en0 2>/dev/null | awk '/inet /{print $2}')"; exit 0 ;;
esac

log "start pid=$$ poll=${POLL}s need=$NEED key=$HOST:$PORT"
# en0 only shows its inet once the cable has carrier, so check the configured address instead
networksetup -getinfo Ethernet 2>/dev/null | grep -q "^IP address: $MYIP$" \
  || log "WARNING Ethernet is not configured as $MYIP (networksetup -setmanual Ethernet $MYIP 255.255.255.0)"
ifconfig en0 2>/dev/null | grep -q 'status: active' || log "NOTE en0 has no carrier yet: plug the spare Ethernet cable mini en0 <-> iMac"

# Boot kick (measured 2026-11-03 13:50-13:56): after a mini reboot the DP link reads "up" from
# the first poll while the iMac stays black (plain on = black), so the loop below never kicks.
# One KICK at agent start (= every mini boot/login) repairs it; retry until the key answers.
for i in 1 2 3 4 5 6; do
    sleep 10
    if out=$(kick); then log "boot KICK rc=0 (try $i)"; break; fi
    log "boot KICK failed (try $i) ${out:+nc: $out}"
done

last=""; bad=0; backoff=30; last_kick=0; down_since=0
while :; do
    l=$(link); l=${l:-none}
    if [ "$l" != "$last" ]; then
        if [ -n "$last" ] && good "$l" && [ "$down_since" -gt 0 ]; then
            log "link: $l  (repaired after $(( $(date +%s) - down_since ))s)"
        else
            log "link: $l"
        fi
        last=$l
    fi
    if good "$l"; then
        bad=0; backoff=30; down_since=0
    else
        bad=$((bad + 1))
        [ "$down_since" -eq 0 ] && down_since=$(date +%s)
        now=$(date +%s)
        if [ "$bad" -ge "$NEED" ] && [ $((now - last_kick)) -ge "$backoff" ]; then
            out=$(kick); rc=$?
            last_kick=$now
            log "KICK sent (bad=$bad backoff=${backoff}s) rc=$rc ${out:+nc: $out}"
            case $backoff in 30) backoff=60 ;; *) backoff=300 ;; esac
        fi
    fi
    sleep "$POLL"
done
