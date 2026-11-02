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

Permanent alternative to the agent (needs a password on the mini): `sudo pmset -a displaysleep 0 sleep 0 disksleep 0`.

## Troubleshooting

* **Black screen after boot** – the source Mac is not sending a signal (most often the Mac mini's display is asleep: wake it, see *Mac mini side*). Ctrl+Alt+F4, Enter brings the console back.
* **"SMC did not accept the change"** – some boards NAK (`send_byte ... fail: 0x40`). The script retries 4×; if it never takes, that iMac cannot be switched this way (known, unsolved upstream).
* **Key not found at boot** – label must be exactly `TINYCORE`, partition table GPT, FAT32.
* **Verbose boot** – hold a key during GRUB's 0 s timeout is impossible; instead edit `boot/grub/grub.cfg` on the key and set `timeout=5`, pick the second entry.

## Files

* `tdm/` – contents of the extension (`usr/bin/tdm`, `usr/local/tce.installed/tdm`)
* `grub.cfg` – embedded + copied boot config
* `docker/build-linux.sh` – compiles SmcDumpKey (static) and `grub-mkstandalone` inside `debian:bookworm-slim`
* `build.sh` – everything else; `TC_VER=17.x ./build.sh` to move to a newer TinyCore
* `upstream/` – the original project, reference only

---

## راهنمای فارسی

این فلش آی‌مک ۲۰۰۹ تا ۲۰۱۴ را بدون macOS و بدون هارد سالم، چند ثانیه بعد از روشن‌شدن، به حالت مانیتور می‌برد.

اتصال مک مینی به آی‌مک ۲۰۱۰:

- بهترین راه: کابل پسیو USB-C به Mini DisplayPort از پورت تاندربولت مک مینی. کیفیت کامل ۲۵۶۰×۱۴۴۰ و صدا.
- با HDMI: مبدل اکتیو HDMI به Mini DisplayPort (ورودی HDMI، خروجی mDP، با برق USB) که روی ۲۵۶۰×۱۴۴۰ در ۶۰ هرتز کار کند؛ مبدل سمت مک مینی باشد و کابل mDP مستقیم به آی‌مک برود.
- کار نمی‌کند: مبدل پسیو، مبدل سمت آی‌مک، کابل تاندربولت.

ساخت فلش (روی همین مک):

```
brew install squashfs
./build.sh
diskutil list
./build.sh --usb /dev/diskN
```

استفاده: اول کابل مک مینی را وصل کنید، فلش را بزنید، آی‌مک را با نگه‌داشتن Option روشن کنید و EFI Boot را انتخاب کنید. حدود ده ثانیه بعد تصویر مک مینی روی آی‌مک است.

کلیدها (Ctrl+Alt+F و بعد Enter):

- F2 تعویض حالت
- F3 حالت مانیتور روشن
- F4 حالت مانیتور خاموش و برگشت به کنسول
- F5 خاموش‌کردن آی‌مک
- F6 کم و زیاد کردن نور صفحه

اگر صفحه سیاه ماند یعنی مک مینی سیگنال نمی‌فرستد؛ کابل را چک کنید یا F4 و Enter بزنید.
