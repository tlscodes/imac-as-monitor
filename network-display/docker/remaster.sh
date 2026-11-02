#!/bin/bash
# remaster.sh — runs INSIDE a debian:trixie container (build.sh starts it with
#   docker run --rm --privileged --platform linux/amd64 -v cache:/in:ro -v prebuilt:/out -v .:/src:ro)
# Turns the official Debian live "standard" ISO into the iMac-display key payload:
#   /out/filesystem.squashfs  Debian live rootfs + cage + flatpak + OpenDisplay receiver (autostart kiosk)
#   /out/vmlinuz /out/initrd.img
#   /out/BOOTX64.EFI          standalone GRUB with /src/grub.cfg embedded
#   /out/persistence.img      ext4 image, label "persistence", persistence.conf = "/ union"
#   /out/MANIFEST.txt         versions + sizes (evidence for README)
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
ISO=${ISO:-/in/debian-live-13.7.0-amd64-standard.iso}
BUNDLE=${BUNDLE:-/in/od-receiver-x86_64.flatpak}
GRUBCFG=${GRUBCFG:-/src/grub.cfg}
GNOME_RT=${GNOME_RT:-50}
PERSIST_MB=${PERSIST_MB:-1536}
W=/work; R=$W/rootfs
mkdir -p "$W" /out
exec > >(tee /out/remaster.log) 2>&1

apt-get update -qq
apt-get install -qq -y --no-install-recommends squashfs-tools libarchive-tools grub-efi-amd64-bin grub-common \
    e2fsprogs ca-certificates >/dev/null

echo "## 1 ISO -> kernel / initrd / squashfs"
mkdir -p "$W/iso" && cd "$W/iso"
bsdtar -xf "$ISO" 'live/filesystem.squashfs' 'live/vmlinuz*' 'live/initrd.img*'
ls -la live
K=$(ls live/vmlinuz-* 2>/dev/null | head -1 || true);    [ -n "$K" ] || K=live/vmlinuz
I=$(ls live/initrd.img-* 2>/dev/null | head -1 || true); [ -n "$I" ] || I=live/initrd.img
cp "$K" /out/vmlinuz; cp "$I" /out/initrd.img

echo "## 2 unpack rootfs"
rm -rf "$R"; unsquashfs -n -d "$R" live/filesystem.squashfs >/dev/null

echo "## 3 chroot: apt (cage, flatpak, mesa, firmware)"
RESOLV_LINK=$(readlink "$R/etc/resolv.conf" || true)
rm -f "$R/etc/resolv.conf"; cp /etc/resolv.conf "$R/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"; chmod +x "$R/usr/sbin/policy-rc.d"
mount -t proc proc "$R/proc"; mount -t sysfs sys "$R/sys"; mount --bind /dev "$R/dev"; mount -t devpts devpts "$R/dev/pts"
cleanup() { umount -l "$R/dev/pts" "$R/dev" "$R/sys" "$R/proc" 2>/dev/null || true; }
trap cleanup EXIT
# non-free-firmware (firmware-amd-graphics): deb822 and one-line formats; either may be absent (no pipefail trap)
for f in "$R"/etc/apt/sources.list.d/*.sources; do [ -f "$f" ] && sed -i 's/^Components: main$/Components: main non-free-firmware/' "$f"; done
# the ISO ships "deb [trusted=yes] file:/run/live/medium trixie main" — no /run/live/medium in the chroot -> apt-get update rc=100 (run 2, 2026-11-01); drop it for good, the key carries no pool/
[ -f "$R/etc/apt/sources.list" ] && sed -i -E '/file:\/run\/live\/medium/d' "$R/etc/apt/sources.list" || true
[ -f "$R/etc/apt/sources.list" ] && sed -i -E 's/^(deb .*[[:space:]]main)$/\1 non-free-firmware/' "$R/etc/apt/sources.list" || true
grep -rH -E '^Components:|^deb ' "$R/etc/apt/sources.list" "$R"/etc/apt/sources.list.d/ 2>/dev/null || true
chroot "$R" apt-get update -qq
chroot "$R" apt-get install -qq -y --no-install-recommends \
    cage dbus dbus-bin flatpak libgl1-mesa-dri libegl1 libgles2 mesa-va-drivers firmware-amd-graphics firmware-linux-free \
    >/dev/null

echo "## 4 chroot: flatpak (system install, no triggers inside the container)"
chroot "$R" flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
mv "$R/usr/share/flatpak/triggers" "$W/triggers.off"
chroot "$R" flatpak install --system -y --noninteractive flathub "org.gnome.Platform//$GNOME_RT"
FD=$(chroot "$R" flatpak info -m "org.gnome.Platform//$GNOME_RT" | grep -A6 'Extension org.freedesktop.Platform.GL\]' | grep -m1 '^versions=' | cut -d= -f2 | cut -d';' -f1 || true)
FD=${FD:-25.08}
# GL.default//$FD-extra = mesa WITH H.264/H.265 VA-API decode (UVD2 on the HD 5670); the base branch has no video codecs
# and flatpak prefers it when both are installed -> install ONLY the -extra branch, hard-fail if it is missing.
chroot "$R" flatpak install --system -y --noninteractive flathub "org.freedesktop.Platform.GL.default//$FD-extra"
cp "$BUNDLE" "$R/tmp/od.flatpak"
chroot "$R" flatpak install --system -y --noninteractive /tmp/od.flatpak
rm -f "$R/tmp/od.flatpak"
# the app install above auto-pulls the base GL.default//$FD again (rebuild-s9.log line 98) -> remove it LAST, then prove it
chroot "$R" flatpak uninstall --system -y --noninteractive --force-remove "org.freedesktop.Platform.GL.default//$FD" || true
if chroot "$R" flatpak list --columns=application,branch | grep -qE 'GL\.default[[:space:]]+'"$FD"'$'; then
    echo "FATAL: base GL.default//$FD still installed (no VA-API decode)"; exit 1; fi
mv "$W/triggers.off" "$R/usr/share/flatpak/triggers"
chroot "$R" flatpak list --columns=application,version,branch,size

echo "## 5 kiosk: cage + receiver autostart, static network"
cat > "$R/usr/local/bin/od-kiosk" <<'EOF'
#!/bin/bash
# od-kiosk: Wayland kiosk (cage) running the OpenDisplay receiver fullscreen on the iMac panel.
# Evidence rule (2026-11-01, run 1 on the iMac: cursor flicker, persistence image stayed empty): every run
# appends its output to LOGS/ on the FAT32 key itself (readable on the Mac), plus the journal tail on exit.
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
export RUST_LOG=${RUST_LOG:-info}
export WLR_LIBINPUT_NO_DEVICES=1        # a bare iMac has no keyboard/mouse attached
NAME=${OD_NAME:-$(hostname)}
M=/run/live/medium; L=/var/log
if mount -o remount,rw "$M" 2>/dev/null && mkdir -p "$M/LOGS" 2>/dev/null; then L=$M/LOGS; fi
echo "=== od-kiosk $(date '+%F %T') addr [$(hostname -I 2>/dev/null)] log [$L] persistence [$(ls /run/live/persistence 2>/dev/null | tr '\n' ' ')] gpu [$(ls /dev/dri 2>/dev/null | tr '\n' ' ')]" | tee -a "$L/od-receiver.log"
# Owner knobs live on the FAT key (editable from macOS in TextEdit): $M/od-kiosk.conf. Created with defaults on first boot.
C=$M/od-kiosk.conf
if [ ! -s "$C" ]; then cat > "$C" <<'CONF'
# od-kiosk.conf — edit on any computer, save, reboot the iMac. Lines starting with # are ignored.
# Stream size announced to the Mac mini (the GPU scales it to the 2560x1440 panel). Default 2048x1152 = 36 % fewer pixels
# than native; set 2560 / 1440 for native, 1920 / 1080 for the fastest picture.
OD_WIDTH=2048
OD_HEIGHT=1152
# Decoder: avdec_h264 = software (proven on this iMac); vah264dec = Radeon UVD2 hardware (experimental, max 2048x1152;
# the 2026-11-01 log "vah264dec showed no frame (15 pushed)" = it was dropped before it produced a frame); decodebin3 = auto.
OD_DECODER=avdec_h264
# Extra receiver flags, e.g. --no-gl  or  --sink gl
OD_ARGS=
CONF
fi
. "$C" 2>/dev/null || true
export OD_NAME=$NAME OD_WIDTH=${OD_WIDTH:-2048} OD_HEIGHT=${OD_HEIGHT:-1152} OD_DECODER=${OD_DECODER:-avdec_h264} OD_ARGS
echo "od-kiosk: conf [$C] width=$OD_WIDTH height=$OD_HEIGHT decoder=$OD_DECODER args=[$OD_ARGS]" | tee -a "$L/od-receiver.log"
# Recovery rule (2026-11-01 18:20): cage (the compositor) stays up; od-receiver-loop re-spawns the receiver 0.5 s after
# any exit, so a receiver crash/decoder-watchdog exit costs no DRM mode-set and no long black panel. Only a crash loop
# (5 exits < 60 s) or cage itself dying reaches systemd (RestartSec=2). Every exit is logged with rc/signal/uptime.
/usr/local/bin/od-cpu-sample "$L/od-receiver.log" & SAMPLER=$!
dbus-run-session -- cage -s -- /usr/local/bin/od-receiver-loop 2>&1 | tee -a "$L/od-receiver.log"
rc=${PIPESTATUS[0]}
kill "$SAMPLER" 2>/dev/null
{ echo "=== od-kiosk exit rc=$rc $(date '+%F %T')"; journalctl -b --no-pager -n 250; echo "--- dmesg drm/radeon"; dmesg | grep -iE 'drm|radeon' | tail -60; } > "$L/journal-last.txt" 2>&1
echo "=== od-kiosk exit rc=$rc $(date '+%F %T') — cage/dbus session gone (reason: last lines above + journal-last.txt); systemd restarts in 2 s" | tee -a "$L/od-receiver.log"
sync; exit "$rc"
EOF
chmod 755 "$R/usr/local/bin/od-kiosk"

cat > "$R/usr/local/bin/od-receiver-loop" <<'EOF'
#!/bin/bash
# od-receiver-loop: runs INSIDE cage as its only client. Sender relaunch / cable re-plug never exit the receiver
# (it logs connected/disconnected and keeps listening on :9000); this loop covers the cases that DO exit it
# (crash, decoder watchdog, OOM) with a 0.5 s respawn and one "=== receiver exit" line naming rc, signal and uptime.
# 5 exits inside 60 s = crash loop -> exit 1 so cage + systemd (RestartSec=2) restart the whole stack.
n=0; win=$(date +%s)
while :; do
  t0=$(date +%s)
  echo "od-loop: receiver start #$((n+1)) $(date '+%F %T') ${OD_WIDTH}x${OD_HEIGHT} decoder=$OD_DECODER args=[$OD_ARGS]"
  flatpak run app.opendisplay.Receiver --name "$OD_NAME" --device "iMac 27 (2010)" --stats-every 10 \
      --width "$OD_WIDTH" --height "$OD_HEIGHT" --decoder "$OD_DECODER" $OD_ARGS
  rc=$?; up=$(( $(date +%s) - t0 ))
  case $rc in
    0)   why="clean exit" ;;
    1)   why="receiver error — see the lines above" ;;
    13[0-9]|14[0-9]|15[0-9]) why="killed by signal $((rc-128)) ($(kill -l $((rc-128)) 2>/dev/null || echo '?'))" ;;
    *)   why="rc $rc" ;;
  esac
  now=$(date +%s); [ $((now - win)) -gt 60 ] && { n=0; win=$now; }
  n=$((n+1))
  echo "=== receiver exit rc=$rc after ${up}s $(date '+%F %T') — $why; respawn in 0.5 s (exit $n in this 60 s window)"
  if [ "$n" -ge 5 ]; then echo "=== receiver crash loop: $n exits in $((now - win)) s — handing over to systemd (cage restart, 2 s)"; exit 1; fi
  sleep 0.5
done
EOF
chmod 755 "$R/usr/local/bin/od-receiver-loop"

cat > "$R/usr/local/bin/od-cpu-sample" <<'EOF'
#!/bin/bash
# od-cpu-sample <logfile>: one line per minute with whole-machine CPU %, load, free memory and the Radeon temperature.
# The receiver's stats line has no cpu field; the README "iMac CPU % while mirroring" row is filled from these lines.
LOG=$1
read -r _ a b c d e f g _ < /proc/stat; pt=$((a+b+c+d+e+f+g)); pi=$((d+e))
while sleep 60; do
  read -r _ a b c d e f g _ < /proc/stat; t=$((a+b+c+d+e+f+g)); i=$((d+e))
  dt=$((t-pt)); di=$((i-pi)); pt=$t; pi=$i
  cpu=0; [ "$dt" -gt 0 ] && cpu=$(( 100 * (dt - di) / dt ))
  temp=$(cat /sys/class/drm/card0/device/hwmon/hwmon*/temp1_input 2>/dev/null | head -1)
  echo "od-cpu: $(date '+%F %T') cpu=${cpu}% load=$(cut -d' ' -f1-3 /proc/loadavg) mem_free=$(awk '/MemAvailable/{printf "%dMiB",$2/1024}' /proc/meminfo)${temp:+ gpu_temp=$((temp/1000))C}" >> "$LOG"
done
EOF
chmod 755 "$R/usr/local/bin/od-cpu-sample"
# --width/--height 2048x1152: the HD 5670's UVD2 decodes at most 2048x1152, so a 2560x1440 stream falls back to software
# on two 2010 cores; announcing 2048x1152 keeps vah264dec and the GPU scales 1.25x to the panel (verified 2026-11-01).
# The iMac is a display only: ignore every input device so a pointer-class HID on it cannot warp the Mac mini cursor.
mkdir -p "$R/etc/udev/rules.d"
echo 'SUBSYSTEM=="input", ENV{LIBINPUT_IGNORE_DEVICE}="1"' > "$R/etc/udev/rules.d/90-od-no-input.rules"

cat > "$R/etc/systemd/system/od-kiosk.service" <<'EOF'
[Unit]
Description=OpenDisplay receiver kiosk (cage) on tty1
After=systemd-user-sessions.service live-config.service systemd-networkd.service
Wants=systemd-networkd.service
Conflicts=getty@tty1.service
After=getty@tty1.service
# never give up: the default start limit (5 starts / 10 s) would leave the panel black for good after a crash loop
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/od-kiosk
Restart=always
# 2 s, not 10: every receiver exit (sender relaunch, decoder watchdog, cable re-plug) showed as a 7-14 s
# "receiver-down" flap on the Mac mini (2026-11-01 17:42, 17:55); the sender reconnects as soon as port 9000 is back
RestartSec=2
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
StandardInput=tty-fail
StandardOutput=journal+console
StandardError=journal+console
UtmpIdentifier=tty1
UtmpMode=user
Environment=XDG_SESSION_TYPE=wayland

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$R/etc/systemd/network"
cat > "$R/etc/systemd/network/10-ethernet.network" <<'EOF'
[Match]
Name=e*

[Network]
Address=10.10.10.2/24
LinkLocalAddressing=ipv4
IPv6AcceptRA=no
LLMNR=no
MulticastDNS=no
ConfigureWithoutCarrier=yes
EOF

chroot "$R" systemctl enable systemd-networkd.service od-kiosk.service
chroot "$R" systemctl mask networking.service        # ifupdown/live-config DHCP must not fight networkd
chroot "$R" systemctl set-default multi-user.target
mkdir -p "$R/var/log/journal"
echo 'kernel.printk = 3 4 1 3' > "$R/etc/sysctl.d/90-quiet.conf"

echo "## 6 clean + squash"
chroot "$R" apt-get clean
rm -rf "$R/var/lib/apt/lists/"* "$R/usr/sbin/policy-rc.d" "$R/tmp/"* "$R/root/.cache"
rm -f "$R/etc/resolv.conf"; [ -n "$RESOLV_LINK" ] && ln -s "$RESOLV_LINK" "$R/etc/resolv.conf" || true
cleanup; trap - EXIT
rm -f /out/filesystem.squashfs
# -mem/-processors: the 4 GiB Docker VM died (unexpected EOF) at this step on run 3, 2026-11-01
mksquashfs "$R" /out/filesystem.squashfs -noappend -comp zstd -Xcompression-level 15 -b 1M -no-progress -processors 2 -mem 768M >/dev/null
SQ=$(stat -c %s /out/filesystem.squashfs)
[ "$SQ" -lt 4294967295 ] || { echo "squashfs $SQ bytes exceeds the FAT32 4 GiB file limit"; exit 1; }

echo "## 7 GRUB EFI + persistence image"
grub-mkstandalone -O x86_64-efi -o /out/BOOTX64.EFI \
    --modules="part_gpt part_msdos fat ext2 search search_label search_fs_uuid linux normal configfile echo sleep test all_video gfxterm efi_gop efi_uga serial terminal" \
    "boot/grub/grub.cfg=$GRUBCFG"
mkdir -p "$W/persist"; echo '/ union' > "$W/persist/persistence.conf"
rm -f /out/persistence.img; truncate -s "${PERSIST_MB}M" /out/persistence.img
mkfs.ext4 -q -F -L persistence -d "$W/persist" /out/persistence.img

{
  echo "built $(date -u +%FT%TZ) from $(basename "$ISO")"
  echo "kernel: $(basename "$K")"
  echo "squashfs: $SQ bytes (zstd)"
  echo "persistence.img: ${PERSIST_MB} MiB ext4 label=persistence (/ union)"
  echo "## debian packages"; chroot_dpkg() { dpkg-query --admindir="$R/var/lib/dpkg" -W -f='${Package} ${Version}\n' "$@"; }
  chroot_dpkg cage flatpak libgl1-mesa-dri mesa-va-drivers firmware-amd-graphics systemd live-boot live-config 2>/dev/null || true
  echo "## flatpaks"; flatpak --installation=none list 2>/dev/null || true
  ls "$R/var/lib/flatpak/app" "$R/var/lib/flatpak/runtime" 2>/dev/null
  echo "## receiver bundle sha256"; sha256sum "$BUNDLE"
} > /out/MANIFEST.txt
cat /out/MANIFEST.txt
ls -la /out
