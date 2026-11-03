# imac-tdm — iMac 2009–2014 as a monitor, from a USB key

Boots a 2009–2014 iMac from a tiny USB key (TinyCore Linux 16, ~25 MB) and flips the
panel to its external Mini DisplayPort input (Target Display Mode) in a few seconds.
No macOS, no working hard drive, no Apple keyboard, no Cmd+F2.

Modern rewrite of [gpdm/tinycore-targetdisplaymode](https://github.com/gpdm/tinycore-targetdisplaymode)
(unmaintained, TinyCore 13, Super Grub2 menu, ISO loopback). Mechanism unchanged:
SMC keys `MVHR`/`MVMR` via [floe/smc_util](https://github.com/floe/smc_util).

| | upstream (2022) | this |
|---|---|---|
| TinyCore | 13, ISO remaster via xorriso | 16.x, kernel + initrd straight from the mirror, md5-checked |
| Boot loader | Super Grub2 Disk menu, manual "Detect and show boot methods" every boot | own `grub-mkstandalone` EFI, timeout 0, boots straight into TDM |
| Build | Docker image `tatsushid/tinycore`, no error checking | one `build.sh` on macOS, Docker only once (cached in `prebuilt/`) |
| USB | manual `diskutil` + copy | `./build.sh --usb /dev/diskN` |
| Controls | tdm_on/off/toggle, cpupower dep | single `tdm` command, retries on SMC NAK, backlight hotkey, no extra packages |

## Hardware: Mac mini (M-series) → iMac 2010

The iMac 27" 2009/2010 (EMC 2390 = iMac11,3) only accepts **Mini DisplayPort** on its
external input. Nothing in software changes that port. Two cables that work:

1. **Best:** passive **USB-C → Mini DisplayPort cable** (DP Alt Mode) from any Thunderbolt/USB-C
   port of the Mac mini. Native 2560×1440@60, audio over DP. No adapter, no power.
2. **HDMI:** **active HDMI → Mini DisplayPort converter** (HDMI in, mDP out, USB-powered) from the
   Mac mini's HDMI port. Pick one rated 2560×1440@60 (many cheap ones stop at 1080p).
   Plug the converter on the Mac mini side and run a straight mDP cable to the iMac.

Not working: HDMI→mDP *passive* adapters, mDP→HDMI adapters at the iMac end, Thunderbolt cables
(2010 iMac has no Thunderbolt; 2011+ iMacs want Thunderbolt instead).

## Build (macOS)

```
brew install squashfs          # mksquashfs
./build.sh                     # -> dist/   (Docker runs once, result cached in prebuilt/)
diskutil list                  # find your USB key, e.g. /dev/disk4
./build.sh --usb /dev/disk4    # ERASES the key: GPT + FAT32 "TINYCORE", copies dist/
```

Key layout:

```
EFI/BOOT/BOOTX64.EFI   GRUB standalone, grub.cfg embedded
boot/vmlinuz64         TinyCore 16 kernel
boot/corepure64.gz     TinyCore 16 initrd
boot/grub/grub.cfg     editable copy, overrides the embedded one
tce/onboot.lst         "tdm.tcz"
tce/optional/tdm.tcz   SmcDumpKey (static) + /usr/bin/tdm + boot hook
```

## Use

1. Cable the Mac mini to the iMac first, plug in the key.
2. Power the iMac on holding **Option**, choose **EFI Boot**.
3. ~10 s later the panel shows the Mac mini. Done.

Hotkeys (press Ctrl+Alt+F<n>, then Enter):

| key | action |
|---|---|
| F2 | toggle external / local |
| F3 | external input ON |
| F4 | external input OFF (local Linux console) |
| F5 | power off the iMac |
| F6 | backlight 100 → 70 → 40 % |

CLI on F1: `tdm on|off|toggle|status|bright 0-100|poweroff`.

## Mac mini side (optional, no sudo)

`tools/mini/install-display-off.sh [user@host]` installs over ssh:

* **Screen Off.app** (`~/Applications`, pinned to the Dock) - one click puts the mini's displays to sleep; the iMac panel goes dark; any mouse/keyboard event brings the picture back in ~2 s. Nothing reboots, TDM is untouched.
* **LaunchAgent `com.imac-tdm.keep-display-awake`** - holds `caffeinate -d -i -s` so the mini never *idle*-sleeps its display. Without it, display sleep on the mini (default 10 min) drops the DisplayPort link and the iMac shows black or a stale frame.
* `~/od-sender/display-off.sh` - the same thing from a terminal / ssh.
* **LaunchAgent `com.imac-tdm.link-watch`** (`tdm-link-watch.sh`, installed by
  `tools/mini/install-on-mini.sh`) - the second line of the post-reboot fix (the first line lives on the
  key, see *Mac mini reboot* below). It reads `ioreg … LinkRateDescription` every 10 s; two `No Link`
  readings in a row send one line `KICK` to `10.10.10.2:9100` over the spare Ethernet cable, and it sends
  one `KICK` when it starts (= every login). Backoff 30/60/300 s.
  `~/od-sender/tdm-link-watch.sh kick|status` for a manual kick / one status line;
  log `~/Library/Logs/tdm-link-watch.log` (mini) and `tce/log/kick.log` (key).
* Turn the mini's automatic macOS updates off, or it will reboot on its own again (one script, asks for
  the password once): `sudo ~/od-sender/no-autoupdate.sh` (= `softwareupdate --schedule off` + the three
  `defaults write` lines for AutomaticallyInstallMacOSUpdates / AutomaticDownload / commerce AutoUpdate).

Permanent alternative to the agent (needs a password on the mini): `sudo pmset -a displaysleep 0 sleep 0 disksleep 0`.

## Mac mini reboot: the picture comes back by itself (spare Ethernet cable)

Hardware truth, measured 2026-11-03: after **any** reboot of the Mac mini the iMac goes black and stays
black. The mini re-trains the DisplayPort link, the SMC on the iMac still says "external" (`MVHR=1`),
so `tdm-guard` sees nothing wrong, and nothing on the mini side can fix it. The only repair is
TDM **off, 3 s, on** on the iMac, the same kick the key does 10 s after its own boot.

Two things make this automatic. Both need one **straight Ethernet cable** between the mini's Ethernet
port and the iMac's Ethernet port (no switch, no router). The key configures the iMac side as
`10.10.10.2/24`; `install-on-mini.sh` sets the mini's `en0` to `10.10.10.1/24` manually.

1. **On the key: `tdm-kickd`** (started by the boot hook after the boot kick). It listens on TCP 9100
   for `KICK` and, independently, **watches the cable carrier**: when the carrier drops for 3 s or more
   and comes back, the mini has rebooted, and the key kicks itself at +15 s and again at +45 s.
   This works **before anyone types a password** on the mini.
   Why that matters: with FileVault on, a rebooted mini runs *no* user agent and *no* third-party
   LaunchDaemon until the pre-boot password is entered (ssh even prints "This system is locked"), so a
   mini-side watcher alone can never repair a reboot. Only the key is awake at that moment.
2. **On the mini: `tdm-link-watch`** (above) covers everything after login: a dropped link while the
   mini is up, and one kick at login because the desktop re-trains the link once more.

What you see: picture → black → picture after about 30–45 s, and each kick is a visible 2–3 s
off/on blink. The blink is the repair, not a fault; it only happens at iMac boot, after a mini reboot,
or when you unplug/replug the Ethernet cable. Shortening the 3 s has not been tested (kicking too early
is known to leave the panel black for good), so leave it.

Gate on the key: a kick is ignored while Ctrl+Alt+F4 (manual off) is active, and at most one kick per
20 s whoever asks. Logs: `tce/log/kick.log` on the key (every carrier change and kick, with uptime),
`~/Library/Logs/tdm-link-watch.log` on the mini.

Test it: `ssh user@mac-mini.local 'osascript -e "tell application \"System Events\" to restart"'`
and do not touch anything. The picture must be back in under a minute with no password typed.

## Troubleshooting

* **Black screen after boot** – the source Mac is not sending a signal (most often the Mac mini's display is asleep: wake it, see *Mac mini side*). Ctrl+Alt+F4, Enter brings the console back.
* **Black after the Mac mini rebooted** – wait 45 s with the Ethernet cable connected (the key kicks at
  +15 s and +45 s after the cable carrier returns). Still black: `~/od-sender/tdm-link-watch.sh kick`
  from the mini once it is logged in, or Ctrl+Alt+F4, Enter, Ctrl+Alt+F3, Enter on the iMac keyboard.
  No cable = no auto-repair; the mini cannot do it alone (FileVault, see above).
* **Picture blinks off for 3 s and returns** – that is the kick, expected after iMac boot, mini reboot
  or an Ethernet replug. If it blinks in normal use, read `tce/log/kick.log`: it names who asked.
* **"mouse move no longer brings the iMac back" after hours** – the mini rebooted on its own
  (macOS auto-update). Run `sudo ~/od-sender/no-autoupdate.sh` once; the auto-repair above covers the
  reboot itself.
* **"SMC did not accept the change"** – some boards NAK (`send_byte ... fail: 0x40`). The script retries 4×; if it never takes, that iMac cannot be switched this way (known, unsolved upstream).
* **Key not found at boot** – label must be exactly `TINYCORE`, partition table GPT, FAT32.
* **Verbose boot** – hold a key during GRUB's 0 s timeout is impossible; instead edit `boot/grub/grub.cfg` on the key and set `timeout=5`, pick the second entry.

## Files

* `tdm/` – contents of the extension: `usr/bin/tdm` (SMC switch), `usr/bin/tdm-guard` (SMC watchdog),
  `usr/bin/tdm-kickd` (Ethernet kick server + mini-reboot watcher), `usr/bin/tdm-flush` (logs to the key),
  `usr/local/tce.installed/tdm` (boot hook: switch, 10 s boot kick, start guard and kickd)
* `tools/mini/` – Mac mini side: `install-on-mini.sh` (link-watch agent + Ethernet 10.10.10.1, no sudo),
  `install-display-off.sh` (Screen Off.app + keep-display-awake agent), `no-autoupdate.sh` (sudo once)
* `grub.cfg` – embedded + copied boot config
* `docker/build-linux.sh` – compiles SmcDumpKey (static) and `grub-mkstandalone` inside `debian:bookworm-slim`
* `build.sh` – everything else; `TC_VER=17.x ./build.sh` to move to a newer TinyCore
* `upstream/` – the original project, reference only

---

