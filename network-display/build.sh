#!/bin/bash
# build.sh — macOS driver for the iMac-display USB key (Debian live + OpenDisplay receiver kiosk).
#
#   ./build.sh                       verify downloads, remaster in Docker (if prebuilt/ incomplete), assemble dist/
#   ./build.sh --rebuild             force the Docker remaster even if prebuilt/ is complete
#   ./build.sh --image KEY.dmg [--serial]   also write a GPT/FAT32 disk image of dist/ (QEMU test; --serial = ttyS0 default entry)
#   ./build.sh --usb /dev/diskN [--yes]     also write the physical key (guards: external/removable, <=64 GB, TINYCORE|DEBLIVE)
#   ./build.sh --usb-sync /dev/diskN [--yes] [--with-persistence]   replace ONLY changed files on an existing DEBLIVE key
#                                            (SHA256SUMS sidecar; harvests LOGS/ -> .test/key-logs/; never deletes)
#
# Layout of the key / image (GPT, one FAT32 partition labelled DEBLIVE — the same layout that already
# booted this iMac with TinyCore): EFI/BOOT/BOOTX64.EFI, boot/grub/grub.cfg, live/{vmlinuz,initrd.img,
# filesystem.squashfs}, persistence (ext4 image file, label "persistence", found by live-boot as a
# persistence *file* because dd onto a partition needs sudo on macOS).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CACHE=$HERE/cache; PRE=$HERE/prebuilt; DIST=$HERE/dist; TEST=$HERE/.test
ISO=debian-live-13.7.0-amd64-standard.iso
BUNDLE=od-receiver-x86_64.flatpak
DOCKER_IMAGE=${DOCKER_IMAGE:-debian:trixie}
WORKVOL=${WORKVOL:-imac-display-work}

REBUILD=0; IMAGE=""; SERIAL=0; USB=""; SYNC=""; YES=0; WITH_PERSIST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rebuild) REBUILD=1 ;;
    --image)   IMAGE=${2:?--image needs a path}; shift ;;
    --serial)  SERIAL=1 ;;
    --usb)     USB=${2:?--usb needs /dev/diskN}; shift ;;
    --usb-sync) SYNC=${2:?--usb-sync needs /dev/diskN}; shift ;;
    --with-persistence) WITH_PERSIST=1 ;;
    --yes)     YES=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac; shift
done
log() { printf '[build %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
mkdir -p "$PRE" "$TEST"

# check_disk /dev/diskN — the guards every key operation shares; sets DISK (whole) and USBN (diskN).
check_disk() {
  USBN=${1#/dev/}; USBN=${USBN#r}; DISK=/dev/$USBN
  info=$(diskutil info "$DISK" 2>/dev/null) || die "no such disk $DISK"
  printf '%s\n' "$info" | grep -q 'Whole:  *Yes' || die "$DISK is not a whole disk"
  bootwhole=$(diskutil info / | awk -F: '/Part of Whole/{gsub(/ /,"",$2);print $2}')
  [ "$USBN" != "$bootwhole" ] || die "$DISK is the boot disk"
  printf '%s\n' "$info" | grep -q -E 'Removable Media: *Removable|Device Location: *External' || die "$DISK is not removable/external"
  bytes=$(printf '%s\n' "$info" | sed -n 's/.*Disk Size:.*(\([0-9]*\) Bytes).*/\1/p' | head -1)
  [ -n "$bytes" ] && [ "$bytes" -le 64000000000 ] || die "$DISK size $bytes bytes: refusing (>64 GB or unknown)"
  diskutil list "$DISK" | grep -q -E 'TINYCORE|DEBLIVE' || die "$DISK carries neither TINYCORE nor DEBLIVE — refusing"
  log "target $DISK: $bytes bytes, volumes: $(diskutil list "$DISK" | grep -o -E 'TINYCORE|DEBLIVE' | sort -u | tr '\n' ' ')"
}
if [ -n "$SYNC" ]; then   # sync guards run FIRST: a missing key fails before any 2 GB hashing
  check_disk "$SYNC"
  diskutil list "$DISK" | grep -q DEBLIVE || die "$DISK carries TINYCORE but no DEBLIVE — sync needs the existing layout (use --usb)"
fi

# ---- 1 inputs -------------------------------------------------------------------------------------
log "verify downloads"
[ -s "$CACHE/$ISO" ] || die "missing $CACHE/$ISO (see HANDOFF.md downloads)"
[ -s "$CACHE/$BUNDLE" ] || die "missing $CACHE/$BUNDLE"
( cd "$CACHE" && grep " $ISO\$" SHA512SUMS | shasum -a 512 -c - ) || die "ISO sha512 mismatch"
( cd "$CACHE" && shasum -a 256 -c "$BUNDLE.sha256" ) || die "receiver bundle sha256 mismatch"
bash -n "$HERE/docker/remaster.sh"
[ -s "$HERE/grub.cfg" ] || die "missing grub.cfg"

# ---- 2 remaster (Docker, Linux tools) ------------------------------------------------------------
PRE_FILES=(filesystem.squashfs vmlinuz initrd.img BOOTX64.EFI persistence.img MANIFEST.txt)
complete=1; for f in "${PRE_FILES[@]}"; do [ -s "$PRE/$f" ] || complete=0; done
if [ "$complete" = 1 ] && [ "$REBUILD" = 0 ]; then
  log "prebuilt/ complete — skipping Docker remaster (use --rebuild to force)"
else
  command -v docker >/dev/null || die "docker not found"
  docker info >/dev/null 2>&1 || die "docker daemon not running"
  log "docker remaster start (image $DOCKER_IMAGE, work volume $WORKVOL) — this takes a long time"
  docker volume create "$WORKVOL" >/dev/null
  set +e
  docker run --rm --privileged --platform linux/amd64 \
    -v "$CACHE":/in:ro -v "$PRE":/out -v "$HERE":/src:ro -v "$WORKVOL":/work \
    -e ISO=/in/$ISO -e BUNDLE=/in/$BUNDLE -e GRUBCFG=/src/grub.cfg \
    "$DOCKER_IMAGE" bash /src/docker/remaster.sh
  rc=$?; set -e
  [ "$rc" = 0 ] || die "remaster failed rc=$rc — read $PRE/remaster.log"
  for f in "${PRE_FILES[@]}"; do [ -s "$PRE/$f" ] || die "remaster finished but $PRE/$f is missing"; done
  log "docker remaster done"
fi
SQ=$(stat -f %z "$PRE/filesystem.squashfs")
[ "$SQ" -lt 4294967295 ] || die "filesystem.squashfs is $SQ bytes: over the FAT32 4 GiB limit"

# ---- 3 assemble dist/ (incremental: a copy is skipped when the destination is byte-identical) ------
log "assemble dist/"
mkdir -p "$DIST/EFI/BOOT" "$DIST/boot/grub" "$DIST/live"
icp() { [ -f "$2" ] && cmp -s "$1" "$2" || cp "$1" "$2"; }
icp "$PRE/BOOTX64.EFI"        "$DIST/EFI/BOOT/BOOTX64.EFI"
icp "$HERE/grub.cfg"          "$DIST/boot/grub/grub.cfg"
icp "$PRE/vmlinuz"            "$DIST/live/vmlinuz"
icp "$PRE/initrd.img"         "$DIST/live/initrd.img"
icp "$PRE/filesystem.squashfs" "$DIST/live/filesystem.squashfs"
icp "$PRE/persistence.img"    "$DIST/persistence"
icp "$PRE/MANIFEST.txt"       "$DIST/MANIFEST.txt"
# SHA256SUMS of every regular file under dist/ (relative paths); per-file cache keyed "size mtime path"
# in prebuilt/SHA256SUMS.cache so an unchanged 2 GB squashfs is not re-hashed every run.
hash_tree() { # hash_tree <root> <cachefile>  -> prints "<sha>  <relpath>" lines
  local root=$1 cache=$2 rel key sha; touch "$cache"
  ( cd "$root" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort ) | while IFS= read -r rel; do
    key="$(stat -f '%z %m' "$root/$rel") $rel"
    sha=$(grep -F -- " $key" "$cache" | head -1 | cut -d' ' -f1 || true)
    if [ -z "$sha" ]; then sha=$(shasum -a 256 "$root/$rel" | cut -d' ' -f1); printf '%s %s\n' "$sha" "$key" >> "$cache"; fi
    printf '%s  %s\n' "$sha" "$rel"
  done
}
hash_tree "$DIST" "$PRE/SHA256SUMS.cache" > "$DIST/SHA256SUMS"
DIST_BYTES=$(du -sk "$DIST" | cut -f1); DIST_BYTES=$((DIST_BYTES * 1024))
log "dist/ = $((DIST_BYTES / 1048576)) MiB, $(wc -l < "$DIST/SHA256SUMS" | tr -d ' ') files hashed"; ls -la "$DIST" "$DIST/live"

copy_tree() { # copy_tree <mountpoint> [serial]
  local mp=$1
  cp -R "$DIST"/. "$mp"/
  [ "${2:-0}" = 1 ] && sed -i '' 's/^set default=od$/set default=od_serial/' "$mp/boot/grub/grub.cfg"
  sync
  ls -la "$mp" "$mp/live" "$mp/EFI/BOOT"
}
mount_key() { # mount_key -> MP=/Volumes/DEBLIVE
  MP=/Volumes/DEBLIVE; i=0
  [ -d "$MP" ] || diskutil mount "${DISK}s2" >/dev/null 2>&1 || true
  until [ -d "$MP" ] || [ $i -ge 30 ]; do sleep 1; i=$((i+1)); done
  [ -d "$MP" ] || die "DEBLIVE did not mount"
}

# ---- 4 --image: GPT/FAT32 disk image (QEMU) -------------------------------------------------------
if [ -n "$IMAGE" ]; then
  mkdir -p "$(dirname "$IMAGE")"
  need_mb=$(( DIST_BYTES / 1048576 + 768 )); [ "$need_mb" -lt 4096 ] && need_mb=4096
  log "create $IMAGE (${need_mb} MiB, GPT, FAT32 DEBLIVE)"
  rm -f "$IMAGE"
  hdiutil create -size "${need_mb}m" -layout GPTSPUD -fs "MS-DOS FAT32" -volname DEBLIVE -format UDRW -ov "$IMAGE" >/dev/null
  [ -f "$IMAGE" ] || IMAGE_REAL="$IMAGE.dmg"
  IMAGE_REAL=${IMAGE_REAL:-$IMAGE}
  att=$(hdiutil attach -nobrowse -readwrite "$IMAGE_REAL")
  MP=$(printf '%s\n' "$att" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
  DEV=$(printf '%s\n' "$att" | awk 'NR==1{print $1}')
  [ -d "$MP" ] || die "image did not mount: $att"
  copy_tree "$MP" "$SERIAL"
  hdiutil detach "$DEV" >/dev/null
  [ "$IMAGE_REAL" = "$IMAGE" ] || mv -f "$IMAGE_REAL" "$IMAGE"
  log "image ready: $IMAGE ($(stat -f %z "$IMAGE") bytes)"
fi

# ---- 5 --usb: physical key, full write -----------------------------------------------------------------
if [ -n "$USB" ]; then
  check_disk "$USB"
  LOG=$TEST/usb-write.log; : > "$LOG"
  if [ "$YES" != 1 ]; then
    log "dry run — would: diskutil partitionDisk $DISK GPT MS-DOS DEBLIVE 0 ; cp dist/ ; eject.  Add --yes to write."
    exit 0
  fi
  {
    log "erase + partition $DISK"
    diskutil unmountDisk force "$DISK" || true
    diskutil partitionDisk "$DISK" GPT MS-DOS DEBLIVE 0
    mount_key
    log "copy dist/ -> $MP"
    copy_tree "$MP" 0
    diskutil eject "$DISK"
    log "USB key ready: $DISK (DEBLIVE, GPT, $((DIST_BYTES / 1048576)) MiB written)"
    diskutil list "$DISK" 2>/dev/null || true
  } 2>&1 | tee -a "$LOG"
fi

# ---- 6 --usb-sync: replace only changed files (user law 2026-11-01: a full write = 12 min on USB 2.0) ----
if [ -n "$SYNC" ]; then
  LOG=$TEST/usb-sync.log
  if [ "$YES" != 1 ]; then
    log "dry run — would mount ${DISK}s2, harvest LOGS/, copy files whose SHA256SUMS entry differs, eject.  Add --yes."
    exit 0
  fi
  {
    mount_key
    if [ -d "$MP/LOGS" ]; then
      H=$TEST/key-logs/$(date +%Y%m%d-%H%M); mkdir -p "$H"; cp -R "$MP/LOGS/." "$H/"
      log "harvested LOGS/ -> $H: $(ls "$H" | tr '\n' ' ')"
    else log "no LOGS/ on the key (iMac not booted since last write?)"; fi
    if [ -s "$MP/SHA256SUMS" ]; then cp "$MP/SHA256SUMS" "$TEST/key.sums"
    else log "first sync: hashing key"; hash_tree "$MP" "$TEST/key.sums.cache" > "$TEST/key.sums"; fi
    n=0; mib=0
    while IFS= read -r line; do
      sha=${line%%  *}; rel=${line#*  }
      if [ "$rel" = persistence ] && [ -f "$MP/persistence" ] && [ "$WITH_PERSIST" != 1 ]; then log "persistence kept"; continue; fi
      if [ -f "$MP/$rel" ] && grep -q -F -- "$sha  $rel" "$TEST/key.sums"; then continue; fi
      mkdir -p "$(dirname "$MP/$rel")"; cp "$DIST/$rel" "$MP/$rel"
      sz=$(stat -f %z "$DIST/$rel"); n=$((n+1)); mib=$((mib + sz / 1048576)); log "copied $rel ($((sz / 1048576)) MiB)"
    done < "$DIST/SHA256SUMS"
    cp "$DIST/SHA256SUMS" "$MP/SHA256SUMS"; sync
    diskutil eject "$DISK"
    log "USB key synced: $n files, $mib MiB"
  } 2>&1 | tee -a "$LOG"
fi
log "done"
