#!/bin/bash
# Build a bootable "iMac -> monitor" USB key for 2009-2014 iMacs (Target Display Mode)
# on TinyCore Linux 16, from macOS. No ISO remastering, no Super Grub2 menu:
# the key boots straight into TDM in a few seconds.
#
#   ./build.sh                 -> builds ./dist (copy its contents to a FAT32 key labelled TINYCORE)
#   ./build.sh --usb /dev/diskN -> builds, then ERASES diskN, formats it GPT+FAT32 "TINYCORE" and copies dist
#
# Needs: curl, mksquashfs (brew install squashfs), docker (only the first time:
# compiles SmcDumpKey and grub-mkstandalone; results are cached in ./prebuilt).
set -euo pipefail
cd "$(dirname "$0")"
TC_VER=${TC_VER:-16.x}
TC_BASE="http://tinycorelinux.net/${TC_VER}/x86_64/release/distribution_files"
CACHE=cache; PRE=prebuilt; DIST=dist

log() { printf '\n## %s\n' "$*"; }

log "1/5 TinyCore kernel + initrd (${TC_VER})"
mkdir -p "$CACHE"
for f in vmlinuz64 corepure64.gz; do
    [ -s "$CACHE/$f.md5.txt" ] || curl -fsSL -o "$CACHE/$f.md5.txt" "$TC_BASE/$f.md5.txt"
    want=$(awk '{print $1}' "$CACHE/$f.md5.txt")
    if [ ! -s "$CACHE/$f" ] || [ "$(md5 -q "$CACHE/$f")" != "$want" ]; then
        curl -fL -o "$CACHE/$f" "$TC_BASE/$f"
    fi
    [ "$(md5 -q "$CACHE/$f")" = "$want" ] || { echo "md5 mismatch for $f"; exit 1; }
    echo "ok  $f  $want"
done

log "2/5 SmcDumpKey (static) + GRUB EFI loader"
if [ ! -s "$PRE/SmcDumpKey" ] || [ ! -s "$PRE/BOOTX64.EFI" ] || [ grub.cfg -nt "$PRE/BOOTX64.EFI" ]; then
    [ -d smc_util ] || git clone -q https://github.com/floe/smc_util.git smc_util
    mkdir -p "$PRE"
    docker run --rm --platform linux/amd64 \
        -v "$PWD:/in:ro" -v "$PWD/$PRE:/out" debian:bookworm-slim sh /in/docker/build-linux.sh
else
    echo "cached in $PRE/"
fi

log "3/5 tdm.tcz extension"
chmod 755 tdm/usr/bin/tdm tdm/usr/bin/tdm-guard tdm/usr/bin/tdm-flush tdm/usr/local/tce.installed/tdm
rm -rf build && mkdir -p build/pkg
cp -R tdm/. build/pkg/
cp "$PRE/SmcDumpKey" build/pkg/usr/bin/SmcDumpKey && chmod 755 build/pkg/usr/bin/SmcDumpKey
mksquashfs build/pkg build/tdm.tcz -noappend -quiet -no-progress -no-xattrs -all-root -comp gzip >/dev/null
echo "ok  tdm.tcz $(stat -f %z build/tdm.tcz) bytes"

log "4/5 assemble $DIST/"
rm -rf "$DIST"
mkdir -p "$DIST/EFI/BOOT" "$DIST/boot/grub" "$DIST/tce/optional"
cp "$PRE/BOOTX64.EFI"      "$DIST/EFI/BOOT/BOOTX64.EFI"
cp "$CACHE/vmlinuz64"      "$DIST/boot/vmlinuz64"
cp "$CACHE/corepure64.gz"  "$DIST/boot/corepure64.gz"
cp grub.cfg                "$DIST/boot/grub/grub.cfg"
cp build/tdm.tcz           "$DIST/tce/optional/tdm.tcz"
echo "tdm.tcz" >           "$DIST/tce/onboot.lst"
touch "$DIST/tce/copy2fs.flg"   # load extension into RAM so the USB key can idle
find "$DIST" -type f | sort | xargs ls -la

log "5/5 USB"
if [ "${1:-}" = "--usb" ]; then
    disk=${2:?usage: --usb /dev/diskN}
    diskutil info "$disk" | grep -E 'Device Node|Device / Media Name|Disk Size|Removable Media|Protocol'
    read -r -p "ERASE $disk and write the TDM key? type YES: " ans
    [ "$ans" = "YES" ] || { echo "aborted"; exit 1; }
    diskutil partitionDisk "$disk" 1 GPT MS-DOS TINYCORE 0
    vol=/Volumes/TINYCORE
    [ -d "$vol" ] || { echo "mount point $vol missing"; exit 1; }
    cp -R "$DIST"/. "$vol"/
    sync
    diskutil eject "$disk"
    echo "USB key ready: plug into the iMac, power on holding Option, pick 'EFI Boot'."
else
    echo "dist/ ready. Format a key as GPT + FAT32 labelled TINYCORE and copy dist/* to its root,"
    echo "or rerun:  ./build.sh --usb /dev/diskN   (see: diskutil list)"
fi
