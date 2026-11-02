# OpenDisplay Linux receiver — facts read before building (2026-11-01)

Sources read: https://opendisplay.app , https://opendisplay.app/docs/linux/receiver/ ,
https://github.com/peetzweg/opendisplay (README, PROTOCOL.md, linux/README.md,
linux/packaging/flatpak/app.opendisplay.Receiver.yml, linux/testbench/cage-smoke.sh,
linux/crates/od-receiver/src/{main,lib,discovery,video}.rs), release page v1.30.1 (2026-10-29).

## x86_64 receiver exists
- Release v1.30.1 assets: `od-receiver-x86_64.flatpak` (1.69 MB),
  sha256 `6469f85414a8ae08d5a35506a954ddc0d31414205d12cc22a02f85fe1ef39e65`;
  `od-receiver-aarch64.flatpak`; no AppImage / .deb.
- Download base: `https://github.com/peetzweg/opendisplay/releases/download/v1.30.1/`
- Docs: "Download the bundle matching your architecture (`uname -m` prints `x86_64` or `aarch64`)".

## Status / requirements (verbatim)
- "`od-receiver` turns a Linux machine's screen into the display, for a Mac or a Linux desktop."
- "Beta. … tested windowed on Asahi Linux / Hyprland (aarch64), at 24 ms end to end; other desktops are expected to work."
- "It is a GTK 4 window that fills the screen once a sender connects. It draws the sender's cursor and sends pointer input back."
- Fullscreen: "By default, the window goes fullscreen on the first monitor once a sender connects." Fullscreen use is "expected to work but untested."
- Decoding: "Software decoding uses GStreamer (`gst-libav`)." / "VA-API hardware decoding (Intel/AMD, `gst-plugin-va`) is used when installed."
- video.rs: "GStreamer pipeline, chosen so the same binary picks hardware decode where the machine has it (`vah264dec`, `v4l2slh264dec`) and software where not (`avdec_h264`), and presents through `waylandsink` zero-copy when it can."
- Flatpak manifest (app.opendisplay.Receiver.yml): `runtime: org.gnome.Platform`, `runtime-version: '50'`, `command: od-receiver`,
  finish-args `--share=network --share=ipc --socket=wayland --socket=fallback-x11 --device=all`.
  Comment: "H.264 decode: the runtime's GStreamer plays H.264 through openh264dec or, with the auto-installed org.freedesktop.Platform.codecs-extra extension, avdec_h264".
- No GPU / OpenGL requirement is stated anywhere. GTK 4 needs OpenGL (or falls back to cairo); Radeon HD 5xxx = Mesa r600 (GL 4.5) — assumption A1 in run.json.
- Security: "the stream is not encrypted. Use it on a network you trust." (direct cable = trusted)

## Install (verbatim)
```
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user od-receiver-x86_64.flatpak     # or od-receiver-aarch64.flatpak
flatpak run app.opendisplay.Receiver
```
"The GNOME runtime comes from Flathub." Autostart: "Flatpak: add `flatpak run app.opendisplay.Receiver` to your desktop's autostart."
(We install `--system` inside the remastered squashfs instead, so the key needs no internet at boot.)

## CLI flags (docs table + main.rs)
| flag | default | purpose |
|---|---|---|
| `--windowed` | off | normal window instead of fullscreen |
| `--output <name>` | first monitor | connector to describe to the sender and fullscreen on |
| `--name <name>` | hostname | name advertised on the network |
| `--listen <addr>` | `0.0.0.0:9000` | TCP listen address |
| `--no-mdns` | off | "Do not advertise via mDNS." |
| `--stats-every <s>` | — | periodic `stats {...}` log line (renderFps etc.) |

## Network / protocol
- PROTOCOL.md: "The **receiver listens** on TCP port **9000** and advertises itself." Bonjour type `_opensidecar._tcp`.
- Cursor side channel: "the official receiver uses TCP port + 1, so 9001 by default" (UDP) → "needs UDP 9001 open in addition to TCP 9000".
- discovery.rs: "Bonjour advertisement (§2.1) with a pure-Rust mDNS responder" (`mdns-sd`) — no avahi needed.
- main.rs: if mDNS fails: "senders must dial {} manually".
- Log line we wait for (lib.rs): `listening on {} ({}x{} @{} scale {}, cursor UDP {:?}, video: {})`; on connect: `sender connected from {addr}`.

## Maximum resolution (site)
- "Otherwise H.264 tops out at 4096×2304 (a 2048×1152 desktop)." / HEVC "up to 5120×2880" (Mac↔Mac only).
- "A non-Retina receiver gets a 2560×1440 desktop, sent 1:1 at 60 fps." → iMac 27" panel 2560×1440 is exactly this case.
- Bandwidth: the stream "uses at most 18 Mb/s" → 1 GbE direct link is far above need.

## macOS sender version
- "Signed & notarized — opens normally on macOS 14+." / "the sending Mac needs 14". Install: `brew install --cask opendisplay`
  or `https://github.com/peetzweg/opendisplay/releases/latest/download/OpenDisplay.dmg`.
- Sender encodes with "Hardware H.264 or HEVC (VideoToolbox real-time mode)"; "frame-dropping backpressure with instant keyframe recovery".

## Upstream kiosk precedent
- linux/testbench/cage-smoke.sh runs the receiver under `cage -d -- od-receiver --listen … --no-mdns --stats-every 1`
  and waits for `grep -q "listening on"` — the same harness our USB key uses (cage kiosk, Wayland, no DE).

## Decision
OpenDisplay is viable for this hardware: an x86_64 receiver exists, it runs on plain Wayland (cage), decodes H.264 in software
when VA-API is absent, and the sender adapts frame rate. Plan A (OpenDisplay) proceeds. Plan B (Sunshine + Moonlight) stays
the fallback only if the receiver fails on the real Radeon HD 5xxx at step s5.
