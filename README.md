# imac-as-monitor — use an old iMac as a display for a modern Mac (or anything)

Two independent, tested routes to turn a 2009–2014 iMac into a monitor. Both boot the iMac from a
small USB key (no macOS, no working hard drive, no Apple keyboard needed) and need nothing on the
iMac's disk.

| Route | Folder | Cable | Picture | Best for |
|---|---|---|---|---|
| **Direct cable (Target Display Mode)** | [`cable-tdm/`](cable-tdm/) | USB-C/Thunderbolt → Mini DisplayPort | native 2560×1440 @ 60 Hz, zero latency | iMac 27" 2009–2010 (Mini DisplayPort models) |
| **Network display (OpenDisplay)** | [`network-display/`](network-display/) | one Ethernet cable | H.264/HEVC stream, ~2048×1152 | any iMac that boots a USB key; no DisplayPort cable |

Tested hardware: iMac 27" Mid 2010 (iMac11,3, EMC 2390) as the display, Apple Mac mini (M-series) as
the source. Apple's own Target Display Mode spec stops at 2019 source Macs; the cable route works on a
modern Mac mini because it drives the panel through the iMac's SMC, not through macOS.

## 1. Direct cable — `cable-tdm/`

A ~25 MB TinyCore Linux 16 key. At boot it flips the panel to the external Mini DisplayPort input via
the SMC keys `MVHR`/`MVMR` (mechanism from [floe/smc_util](https://github.com/floe/smc_util) and
[gpdm/tinycore-targetdisplaymode](https://github.com/gpdm/tinycore-targetdisplaymode)).

- `tdm-guard` turns TDM on once at boot and re-applies the proven off/on recovery if the SMC drops
  the routing; it never fights a manual off. Log on the iMac: `/tmp/tdm-guard.log`.
- Kernel lines carry `consoleblank=0` so the console never blanks the panel after 10 minutes.
- Console hotkeys on the iMac keyboard: Ctrl+Alt+F2 toggle · F3 on · F4 off · F5 power off · F6 brightness 100/70/40.
- Lost picture? Ctrl+Alt+F4, Enter, then Ctrl+Alt+F3, Enter.
- Build and write: `cd cable-tdm && ./build.sh --usb /dev/diskN` (prebuilt EFI loader and `SmcDumpKey`
  are included, so Docker is only needed if you change `grub.cfg`'s embedded copy).

Known limits (honest): a black picture while the SMC still reports "external" is not auto-detected;
audio over the DisplayPort link is not handled by the Linux key yet (the Mac sees a "DisplayPort"
output, the iMac side has no audio driver loaded).

## 2. Network display — `network-display/`

A Debian 13 live key running the OpenDisplay Linux receiver fullscreen in a Wayland kiosk (cage).
The source Mac runs the OpenDisplay macOS sender and treats the iMac as a normal external display.
The two machines are joined by ONE Ethernet cable (10.10.10.1 ↔ 10.10.10.2, mDNS on the link).

- Receiver: pinned software H.264 decode, 2048×1152, auto-respawn; knobs in `od-kiosk.conf` on the
  key's FAT partition. Mac side: `macmini/setup-sender.sh` installs the sender and a launch agent
  that reconnects after sleep.
- Persian setup notes: `network-display/macmini/OpenDisplay_Mac_mini_setup_FA.txt`.
- Build: `cd network-display && ./build.sh` (see its README for the remaster and key-sync steps).

## فارسی

دو روش مستقل و آزمایش‌شده برای اینکه آی‌مک قدیمی مانیتور مک مینی یا هر دستگاه دیگری شود؛ هر دو از یک فلش USB بوت می‌شوند و به دیسک آی‌مک کاری ندارند.

- روش کابلی در پوشهٔ cable-tdm: کابل USB-C به Mini DisplayPort، تصویر بومی ۲۵۶۰×۱۴۴۰ در ۶۰ هرتز و بدون تأخیر؛ برای آی‌مک‌های ۲۰۰۹ و ۲۰۱۰.
- روش شبکه‌ای در پوشهٔ network-display: فقط یک کابل شبکه بین دو دستگاه، تصویر استریم‌شده؛ برای هر آی‌مکی که از فلش بوت شود.
- راهنمای فارسی نصب سمت مک مینی در فایل OpenDisplay_Mac_mini_setup_FA.txt داخل پوشهٔ macmini.

## License

MIT for everything in this repository. Third-party pieces keep their own licenses: TinyCore Linux,
Debian, OpenDisplay, GRUB, `SmcDumpKey` (floe/smc_util).
