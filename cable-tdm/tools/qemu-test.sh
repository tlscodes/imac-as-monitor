#!/bin/bash
# Boot-test dist/ in QEMU (UEFI, USB mass storage) and check that the whole chain
# GRUB -> kernel -> tce (LABEL=TINYCORE) -> tdm.tcz -> /usr/bin/tdm runs.
# The SMC does not exist in QEMU, so the expected end state is the tdm retry message.
#   usage: tools/qemu-test.sh [seconds]   (default 90)
set -euo pipefail
cd "$(dirname "$0")/.."
T=${1:-90}
S=${TMPDIR_TEST:-/tmp/imac-tdm-test}
mkdir -p "$S/qemu"
FW=$(ls /usr/local/share/qemu/edk2-x86_64-code.fd /opt/homebrew/share/qemu/edk2-x86_64-code.fd 2>/dev/null | head -1)
[ -n "$FW" ] || { echo "no EDK2 firmware (brew install qemu)"; exit 1; }

# test copy of dist with serial console enabled (GRUB + kernel), real embedded EFI untouched
rm -rf "$S/qemu/dist" && cp -R dist "$S/qemu/dist"
{
  echo 'serial --unit=0 --speed=115200'
  echo 'terminal_output serial console'
  sed -e 's|quiet loglevel=3|console=tty1 console=ttyS0,115200 loglevel=7|' grub.cfg
} > "$S/qemu/dist/boot/grub/grub.cfg"
rm -f "$S/qemu/key.dmg"
hdiutil create -quiet -srcfolder "$S/qemu/dist" -volname TINYCORE -fs "MS-DOS FAT32" \
    -layout GPTSPUD -format UDRW -size 64m "$S/qemu/key.dmg"
cp "$FW" "$S/qemu/code.fd"

LOG="$S/qemu/serial.log"; : > "$LOG"
qemu-system-x86_64 -machine q35 -m 1024 -cpu max \
    -drive if=pflash,format=raw,readonly=on,file="$S/qemu/code.fd" \
    -drive if=none,id=key,format=raw,file="$S/qemu/key.dmg" \
    -device qemu-xhci -device usb-storage,drive=key \
    -display none -serial "file:$LOG" -monitor none -no-reboot &
Q=$!
for i in $(seq 1 "$T"); do
    sleep 1
    grep -q 'SMC did not accept\|Target Display Mode: ON' "$LOG" 2>/dev/null && break
done
kill $Q 2>/dev/null; wait $Q 2>/dev/null || true

echo "=== serial log: $LOG ($(wc -l < "$LOG") lines)"
grep -n -E 'GRUB|Booting|Core 16|Waiting as requested|tdm|Target Display Mode|SMC|ioperm|tce|Loading extensions|Done' "$LOG" | head -40
echo "=== verdict"
if grep -q 'SMC did not accept' "$LOG"; then
    echo "PASS: GRUB -> kernel -> tce -> tdm.tcz -> tdm on executed (SMC absent in QEMU, as expected)"
else
    echo "FAIL: chain did not reach tdm; see $LOG"; exit 1
fi
