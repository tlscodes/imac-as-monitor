# imac-as-monitor — use an old iMac as a monitor for a modern Mac (Apple Silicon Mac mini, MacBook) or any HDMI/DisplayPort source

**Turn a 2009–2014 iMac into an external display / second monitor, without macOS on the iMac and
without Apple's Target Display Mode limits.** Apple's Target Display Mode needs a 2019-or-older source
Mac and a working macOS on the iMac; this project needs neither. The iMac boots a small Linux USB key
that switches the 27" 2560×1440 panel to the external input (or runs a network display receiver), so
an Apple Silicon Mac mini (tested on the M6; M1/M2/M4/M5 output the same DisplayPort signal), a MacBook or a PC with a DisplayPort output can use the old iMac as a monitor.

Two independent, tested routes. Both boot the iMac from a small USB key (no macOS, no working hard
drive, no Apple keyboard needed) and need nothing on the iMac's disk.

| Route | Folder | Cable | Picture | Best for |
|---|---|---|---|---|
| **Direct cable (Target Display Mode)** | [`cable-tdm/`](cable-tdm/) | USB-C/Thunderbolt → Mini DisplayPort | native 2560×1440 @ 60 Hz, zero latency | iMac 27" 2009–2010 (Mini DisplayPort models) |
| **Network display (OpenDisplay)** | [`network-display/`](network-display/) | one Ethernet cable | H.264/HEVC stream, ~2048×1152 | any iMac that boots a USB key; no DisplayPort cable |

Tested hardware: iMac 27" Mid 2010 (iMac11,3, EMC 2390) as the display, Apple Mac mini M6 (2026, Apple Silicon) as
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

- Mac mini reboot (or a macOS auto-update at night) leaves the iMac black: that is fixed automatically
  when one straight Ethernet cable joins the mini and the iMac. The key's `tdm-kickd` watches the cable
  carrier and kicks the panel (off, 3 s, on) at +15 s and +45 s after the mini comes back, before any
  FileVault password is typed; the mini-side `tdm-link-watch` agent covers link drops after login.
  Tested: remote `osascript restart` of the mini, picture back in under a minute, hands off.
  Setup and the why: `cable-tdm/README.md`, sections *Mac mini side* and *Mac mini reboot*.

Known limits (honest): a black picture while the SMC still reports "external" is only auto-detected
through the Ethernet cable (carrier drop on the key, `No Link` on the mini); without the cable use the
hotkeys. The 2–3 s blink of each kick is the repair itself. Audio over the DisplayPort link is not
handled by the Linux key yet (the Mac sees a "DisplayPort" output, the iMac side has no audio driver loaded).

## 2. Network display — `network-display/`

A Debian 13 live key running the OpenDisplay Linux receiver fullscreen in a Wayland kiosk (cage).
The source Mac runs the OpenDisplay macOS sender and treats the iMac as a normal external display.
The two machines are joined by ONE Ethernet cable (10.10.10.1 ↔ 10.10.10.2, mDNS on the link).

- Receiver: pinned software H.264 decode, 2048×1152, auto-respawn; knobs in `od-kiosk.conf` on the
  key's FAT partition. Mac side: `macmini/setup-sender.sh` installs the sender and a launch agent
  that reconnects after sleep.
- Build: `cd network-display && ./build.sh` (see its README for the remaster and key-sync steps).

## FAQ

**Can I use a 2010 / 2011 iMac as a monitor for an M1, M2, M4, M5 or M6 Mac mini?**
Yes, with the direct-cable route. Apple's Target Display Mode officially stops at 2019 source Macs
because macOS on the *source* must negotiate it; this key switches the panel from the iMac side through
its SMC, so the source only has to output DisplayPort. Tested: iMac 27" Mid 2010 + Mac mini M6 (2026).

**Does it work without macOS on the iMac, with a dead hard drive or SSD?**
Yes. Everything runs from the USB key in RAM; the internal disk is never touched and can be missing.

**Which iMacs?** Mini DisplayPort iMacs (Late 2009 and Mid 2010, 21.5" and 27") for the direct cable
route at native resolution (27": 2560×1440 at 60 Hz). Thunderbolt iMacs (2011–2014) need a
Thunderbolt source for Target Display Mode; the network route works on any iMac that boots a USB key.

**Which cable?** USB-C / Thunderbolt to Mini DisplayPort, *passive* (the Mac's DisplayPort Alt Mode
goes straight to the panel). From HDMI you need an *active* HDMI-to-Mini-DisplayPort converter rated
for 2560×1440 at 60 Hz, placed at the source end; passive HDMI adapters and Thunderbolt cables do not work.

**Is there audio, brightness control, sleep?** Brightness: yes (hotkeys on the iMac keyboard, F6).
Audio over the DisplayPort link: not yet on the Linux key. Sleep: a one-click "Screen Off" app for
the Mac mini is included; the panel wakes on any input.

**The iMac goes black after the Mac mini reboots.** Known hardware behaviour, fixed automatically
when one Ethernet cable joins the two machines (see `cable-tdm/README.md`, *Mac mini reboot*).

**Is this the same as Target Display Mode on Apple Silicon?** It gives the same result (the iMac
panel shows the external Mac at native resolution) without Apple's software requirement on either side.

Search terms this project answers: old iMac as monitor, iMac as external display, iMac as second
monitor, Target Display Mode Apple Silicon, Target Display Mode without macOS, iMac 2010 monitor
mode, iMac 27 2560x1440 display for Mac mini, TinyCore target display mode, OpenDisplay iMac.

## License

MIT for everything in this repository. Third-party pieces keep their own licenses: TinyCore Linux,
Debian, OpenDisplay, GRUB, `SmcDumpKey` (floe/smc_util).
