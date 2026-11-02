# imac-display — iMac 27" (2010) as the 2nd display of a Mac mini M6 over one Ethernet cable

The iMac boots a Debian 13 live USB key that runs the **OpenDisplay** Linux receiver fullscreen in a
Wayland kiosk (cage). The Mac mini runs the OpenDisplay macOS sender (VideoToolbox H.264/HEVC) and
treats the iMac as a normal external display. Nothing is bought, nothing needs internet at the iMac:
the two machines are joined by ONE Ethernet cable (10.10.10.1 ↔ 10.10.10.2, mDNS discovery on the link).

## خلاصه‌ی فارسی
- کلید USB را به آی‌مک بزنید، با Option روشن کنید، EFI Boot را انتخاب کنید؛ بعد از ۱ تا ۲ دقیقه صفحه‌ی گیرنده بالا می‌آید.
- کابل شبکه را مستقیم بین آی‌مک و مک‌مینی وصل کنید.
- روی مک‌مینی اسکریپت زیر را اجرا کنید؛ آی‌مک در منوی OpenDisplay با نام imac27 دیده می‌شود.

```
imac-display/macmini/setup-sender.sh
```

## Files
| path | role |
|---|---|
| `build.sh` | macOS driver: verify downloads → Docker remaster → `dist/` → `--image` (QEMU) / `--usb` (key) |
| `docker/remaster.sh` | runs in `debian:trixie --privileged`: Debian live squashfs + cage + flatpak + receiver, GRUB EFI, persistence image |
| `grub.cfg` | embedded in BOOTX64.EFI and copied to `boot/grub/grub.cfg` on the key (editable without rebuild) |
| `tools/qemu-test.sh` | UEFI boot of the key image under QEMU, waits for the receiver's `listening on` line |
| `macmini/setup-sender.sh` | Mac mini side: sender install, 10.10.10.1 on the cable, wait, open, display list, installs the launch agent below (`--dry-run`) |
| `macmini/od-autoconnect.sh` + `.plist` | launch agent `app.opendisplay.autoconnect` on the Mac mini: keeps 10.10.10.1 on the cable; while the iMac answers it opens the sender (which auto-connects to the remembered `imac27` on launch — zero clicks) and relaunches it when no session exists for 30 s (SIGTERM → `open -a`, max 1×/min, 1×/5 min after 3 misses; `touch ~/.od-autoconnect-pause` to stop that); log `~/Library/Logs/od-autoconnect.log` |
| `docs/RECEIVER-FACTS.md` | verbatim receiver/sender facts from the OpenDisplay docs and sources (evidence for the design) |
| `cache/` | downloads: Debian live 13.7 standard ISO (sha512 checked), `od-receiver-x86_64.flatpak` v1.30.1 (sha256 checked) |
| `prebuilt/` | Docker output: `filesystem.squashfs`, `vmlinuz`, `initrd.img`, `BOOTX64.EFI`, `persistence.img`, `MANIFEST.txt`, `remaster.log` |
| `dist/` | exact content of the key |
| `.test/` | evidence: `build.log`, `qemu/serial.log`, `qemu/screen.png`, `usb-write.log` |

## Key layout
GPT, one FAT32 partition labelled `DEBLIVE` (plus the EFI partition diskutil adds). Same layout that already
booted this iMac with the TinyCore key, so the Mac EFI firmware shows it as "EFI Boot".

```
EFI/BOOT/BOOTX64.EFI        standalone GRUB (grub.cfg embedded)
boot/grub/grub.cfg          on-disk copy, preferred when present
live/vmlinuz  live/initrd.img  live/filesystem.squashfs   (< 4 GiB, zstd)
persistence                 ext4 image, label "persistence", persistence.conf "/ union"
MANIFEST.txt                versions + sizes from the remaster
```

Kernel line: `boot=live components persistence hostname=imac27 noautologin consoleblank=0 net.ifnames=0 quiet loglevel=3`.
GRUB menu (2 s, hidden): default kiosk · verbose · no-persistence · serial (QEMU).

## What runs on the iMac
- `od-kiosk.service` on tty1 (root, logind seat via `PAMName=login`, `Restart=always`):
  `dbus-run-session -- cage -s -- flatpak run app.opendisplay.Receiver --name imac27 --stats-every 10`,
  log mirrored to `/var/log/od-receiver.log` (persistent) and the journal/console.
- `systemd-networkd`: every `e*` interface gets `10.10.10.2/24` + IPv4LL, no DHCP client, `networking.service` masked.
- Flatpak (system install, baked into the squashfs): `org.gnome.Platform//50`, `org.freedesktop.Platform.GL.default`,
  `codecs-extra`, the receiver bundle. Debian side: `cage`, `flatpak`, Mesa r600 (`libgl1-mesa-dri`, `mesa-va-drivers`),
  `firmware-amd-graphics` for the Radeon HD 5xxx.

## Build and test (this Mac)
```
imac-display/build.sh                 # ~1 h: Docker remaster, then dist/
imac-display/tools/qemu-test.sh       # boots dist/ in QEMU, PASS when serial.log shows "listening on"
imac-display/build.sh --usb /dev/disk6 --yes   # writes the key (external, <=64 GB, TINYCORE|DEBLIVE only)
imac-display/build.sh --usb-sync /dev/diskN --yes   # replaces ONLY files whose SHA256SUMS entry changed (sidecar on the key),
                                                    # harvests LOGS/ → .test/key-logs/, keeps persistence unless --with-persistence
```
`build.sh` refuses to write any disk that is internal, larger than 64 GB, the boot disk, or that does not already
carry a TINYCORE or DEBLIVE volume. Without `--yes` it only prints the plan.

## Acceptance (owner at the iMac)
1. Boot the iMac from the key (hold Option, pick "EFI Boot"). Expect: black screen, then the receiver window.
2. Cable iMac ⇄ Mac mini. On the Mac mini run `macmini/setup-sender.sh` (or `--dry-run` first).
3. In the OpenDisplay menu-bar app choose `imac27`. The iMac becomes a display in System Settings ▸ Displays.
4. Evidence to save into `imac-display/acceptance/`:
   - `screenshot.*` — photo of the iMac panel showing the Mac mini's 2nd desktop.
   - `stats.log` — from the iMac: the `listening on …` line and a few `stats {...}` lines
     (verbose GRUB entry shows them on screen; or `cat /var/log/od-receiver.log` after plugging a keyboard, Ctrl+Alt+F2).

### Measured results (fill from `acceptance/stats.log`)
| metric | value | source |
|---|---|---|
| Resolution negotiated | **2048×1152 @60** (pinned in `od-kiosk.conf`; the panel-native 2560×1440 @60 also negotiated on 2026-11-01 11:41 but rendered at 30 fps with 27 ms decode) | `streamConfig h264 2048x1152 @60` (key log 13:54) · Mac mini `system_profiler`: "OpenDisplay — imac27 2048 x 1152 @60.00Hz" (17:25) |
| Video decoder | software **`avdec_h264`** (pinned; `decodebin3` picked `vah264dec` on the HD 5xxx, its watchdog dropped it → renderFps 0 = black screen) | `acceptance/stats.log` session B; `docker/od-kiosk.conf` |
| Stream rate / fps | 18.0 Mb/s, 30 fps sent, **renderFps 30**, 0 stalls, 0 decErr (2560×1440 session, 71 min, 90 k frames) | `acceptance/stats.log` session A |
| iMac CPU % while mirroring | _pending the next boot_ — the `stats {…}` line has no cpu field; since the 2026-11-01 18:20 build `od-cpu-sample` writes one `od-cpu: … cpu=NN% load=… gpu_temp=…` line per minute into `LOGS/od-receiver.log`; fill from the first harvest after that key boots | `LOGS/od-receiver.log` lines `od-cpu:` |
| Latency estimate | **≈ 25 ms glass-to-glass (1–2 frames at 60 Hz) at 2048×1152**: e2e50 6.5 ms + dec50 12.5 ms steady (12.0–13.6 ms over 7 min of motion, up to 58 fps rendered), link RTT 0.6–0.9 ms. The 2560×1440 session measured ≈ 40 ms (e2e50 11 + dec50 27) | `stats {…}` e2e50/dec50, key log 16:25–16:32 UTC (17:25–17:32 CET, first boot with the pinned decoder) |

Sender-side acceptance 2026-11-01 17:25 CET (first boot of the rebuilt key): `od-autoconnect` logged `receiver-up -> streaming` 36 s after the receiver came up, TCP 10.10.10.1 → 10.10.10.2:9000 ESTABLISHED, the iMac is the Mac mini's *main* display.

### Frozen picture after a few idle minutes (2026-11-01 17:57) — root cause and the hardened agent
`pmset -g log`: "Display is turned off" (displaysleep 10 min) → the sender stops encoding, the receiver keeps the last frame (cursor still moves: it is a separate UDP channel), the receiver's no-frame watchdog restarts it (`streaming -> receiver-down -> streaming` flaps at 17:42 and 17:55), and the wake lands on the lock screen. `od-autoconnect.sh` v2 (deployed 18:04, `launchctl kickstart -k gui/$UID/app.opendisplay.autoconnect`) now:
- holds `caffeinate -d -i -s` for its lifetime (no display/idle sleep, no sudo needed) and sets the screen saver idle to 0; tries `sudo -n pmset -a displaysleep 0` once and logs the result;
- probes display power through powerd's "Prevent sleep while display is on" assertion (IODisplayWrangler does not exist on Apple silicon) and wakes a dark display while a session exists;
- detects a **stale session** (owner active, HID idle < 8 s, yet < 1500 B per 5 s tick on the cable for 6 ticks) and relaunches the sender; a static desktop with nobody at the Mac mini never trips it;
- reconnects faster: no session 15 s → relaunch, backoff 20/40/60/300 s, reset after 60 s of streaming; log capped at 1 MB; `od-autoconnect.sh --status` prints one health line.
Owner options that still need the admin password on the Mac mini: `sudo pmset -a displaysleep 0` and `sysadminctl -screenLock off -password -` (no lock screen after a wake). Input is **not** forwarded: a keyboard plugged into the iMac does nothing; type on the Mac mini's own keyboard.

## Troubleshooting
- Black screen > 2 min: boot the "verbose" GRUB entry; look for `od-kiosk`, `cage`, `flatpak run` lines.
- No `listening on`: `flatpak run app.opendisplay.Receiver` from tty2; check `/dev/dri/card0` exists (radeon KMS).
- Sender does not see the iMac: on the Mac mini `dns-sd -B _opensidecar._tcp local.` then `nc -z -G 2 10.10.10.2 9000`;
  dial `10.10.10.2` manually in the sender.
- Everything reset: GRUB entry "Fresh boot, ignore persistence", or delete `persistence` on the key and rebuild it with `build.sh`.
- Zero-click after a reboot — Mac mini: FileVault asks the pre-boot password on its own screen first (never reboot it remotely);
  after that the auto-login user's launch agent opens the sender and it connects by itself. iMac: the key must be the default
  boot device (`bless` from the iMac's macOS, or no internal OS); the agent relaunches the sender once the receiver answers again.
- Receiver answers but no stream for a minute: on the Mac mini `tail ~/Library/Logs/od-autoconnect.log` (expect `relaunch #1`
  within ~60 s) and `ls ~/.od-autoconnect-pause` — remove that file if it exists. The Mac mini sleeps ~10 min after the last
  input (`pmset -g`: displaysleep 10, sleep 1), and the iMac goes dark with it — owner policy, not a bug.

## Plan B (only if the receiver is unusable on the HD 5xxx)
Sunshine on the Mac mini + Moonlight (Flatpak `com.moonlight_stream.Moonlight`) in the same cage kiosk; the key
layout, network and build pipeline stay identical, only the Flatpak bundle and the `od-kiosk` command change.
