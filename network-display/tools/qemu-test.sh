#!/bin/bash
# qemu-test.sh — boot the assembled key image under UEFI QEMU and wait for the receiver's "listening on" line.
#
#   tools/qemu-test.sh            build .test/qemu/key.dmg (build.sh --image --serial), boot it, wait <=20 min
#   WAIT_S=600 tools/qemu-test.sh  shorter wait
#
# Evidence written to imac-display/.test/qemu/: key.dmg, key.raw, serial.log (kernel + od-kiosk + receiver
# log via console=ttyS0 and journal+console), screen.png (QEMU screendump at the end), qemu.log.
# QEMU runs inside Docker (TCG, no GL): brew's qemu is a slow from-source build on this Mac and must not
# be waited for. When /usr/local/bin/qemu-system-x86_64 exists it is used natively with -accel hvf.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$HERE/.test/qemu; mkdir -p "$T"
WAIT_S=${WAIT_S:-1200}
NATIVE=/usr/local/bin/qemu-system-x86_64
log() { printf '[qemu-test %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

log "1/4 build key image"
"$HERE/build.sh" --image "$T/key.dmg" --serial
# UDRW dmg -> plain raw image (UDTO = raw device image; hdiutil appends .cdr)
rm -f "$T/key.raw" "$T/key.cdr"
hdiutil convert -format UDTO -o "$T/key.cdr" "$T/key.dmg" >/dev/null
mv -f "$T/key.cdr" "$T/key.raw"
ls -la "$T/key.raw"

: > "$T/serial.log"; rm -f "$T/screen.png"
QEMU_ARGS=(-machine q35 -m 2048 -smp 2
  -drive if=none,id=key,format=raw,file=/t/key.raw -device qemu-xhci -device usb-storage,drive=key
  -device virtio-vga -netdev user,id=n0 -device e1000,netdev=n0
  -display none -serial file:/t/serial.log -monitor tcp:0.0.0.0:4444,server,nowait -no-reboot)

if [ -x "$NATIVE" ]; then
  log "2/4 boot natively ($NATIVE, hvf)"
  OVMF=$(ls /usr/local/share/qemu/edk2-x86_64-code.fd 2>/dev/null | head -1)
  [ -n "$OVMF" ] || { echo "no edk2-x86_64-code.fd next to native qemu"; exit 1; }
  args=("${QEMU_ARGS[@]//\/t\//$T/}")
  "$NATIVE" -accel hvf -drive "if=pflash,format=raw,readonly=on,file=$OVMF" "${args[@]}" > "$T/qemu.log" 2>&1 &
  QPID=$!; MON_HOST=127.0.0.1
  stop_qemu() { kill "$QPID" 2>/dev/null || true; }
else
  log "2/4 boot in Docker (TCG)"
  docker image inspect imac-display-qemu >/dev/null 2>&1 || \
    printf 'FROM debian:trixie\nRUN apt-get update -qq && apt-get install -qq -y --no-install-recommends qemu-system-x86 ovmf >/dev/null && rm -rf /var/lib/apt/lists/*\n' \
      | docker build -q -t imac-display-qemu - >/dev/null
  docker rm -f imac-display-qemu-run >/dev/null 2>&1 || true
  docker run -d --name imac-display-qemu-run --platform linux/amd64 -p 127.0.0.1:4444:4444 -v "$T":/t imac-display-qemu \
    qemu-system-x86_64 -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd "${QEMU_ARGS[@]}" >/dev/null
  MON_HOST=127.0.0.1
  stop_qemu() { docker logs imac-display-qemu-run > "$T/qemu.log" 2>&1 || true; docker rm -f imac-display-qemu-run >/dev/null 2>&1 || true; }
fi
trap stop_qemu EXIT

log "3/4 wait up to ${WAIT_S}s for 'listening on' in serial.log"
t0=$(date +%s); rc=1
while [ $(( $(date +%s) - t0 )) -lt "$WAIT_S" ]; do
  if grep -q 'listening on' "$T/serial.log" 2>/dev/null; then rc=0; break; fi
  if grep -q -E 'Kernel panic|od-kiosk.service: Failed with result|No space left' "$T/serial.log" 2>/dev/null; then rc=2; break; fi
  sleep 10
done
log "4/4 screendump + summary (rc=$rc after $(( $(date +%s) - t0 ))s)"
monitor() { exec 3<>"/dev/tcp/$MON_HOST/4444" && printf '%s\n' "$1" >&3 && sleep 2 && exec 3>&- ; }
monitor "screendump /t/screen.png -f png" 2>/dev/null || true
sleep 3
echo "--- serial.log: live-boot / kiosk / receiver lines ---"
grep -n -E 'live-boot|persistence|od-kiosk|listening on|cage|flatpak|Failed|error' "$T/serial.log" | tail -40 || true
echo "--- tail ---"; tail -15 "$T/serial.log"
ls -la "$T"
[ "$rc" = 0 ] && log "PASS: receiver is listening" || log "FAIL rc=$rc (read $T/serial.log)"
exit "$rc"
