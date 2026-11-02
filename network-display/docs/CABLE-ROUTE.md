# Direct-cable route (Target Display Mode) — written 2026-11-01, untested until a cable arrives

Hardware truth (imac-tdm notes, 2026-10-31): the iMac 27" 2010 (EMC 2390) has ONE video input, Mini DisplayPort,
usable only in Target Display Mode (TDM). TDM accepts a plain DisplayPort 1.1a signal up to 2560x1440@60 and carries
audio to the iMac speakers. Latency is zero (no encode/decode, no network) — this is the only route that beats the
Ethernet receiver on speed and sound at the same time.

## Cable 1 — one piece: Mac mini M6 Thunderbolt/USB-C -> Mini DisplayPort (PREFERRED)
- Apple-silicon Thunderbolt ports output DisplayPort over USB-C natively (alt mode); a passive USB-C -> mDP cable is enough.
- Buy: "USB-C to Mini DisplayPort cable, 4K@60 / DP 1.2", 1-2 m, any brand that states "Mini DisplayPort MALE" on the far end.
- Expected: 2560x1440@60, audio to the iMac speakers, no adapter power.

## Cable 2 — two pieces: Mac mini HDMI -> BENFEI active HDMI->DisplayPort -> DP->mDP cable (CableDeconn)
- Works only if the BENFEI box is the ACTIVE HDMI-to-DP converter (needs a USB power lead) rated 4K@60 — the passive
  DP->HDMI kind is the wrong direction and will show nothing.
- Expected: 2560x1440@60 if the converter is 4K@60 class; 2560x1440@30 on a 4K@30 class box. Audio passes through.
- More parts, more failure points, uses the Mac mini's only HDMI (the TV port). Cable 1 is better; keep this as fallback.

## What still has to be true on the iMac side (the real risk)
TDM is switched ON by the iMac itself, not by the cable: either macOS on the iMac (Cmd+F2) or the archived imac-tdm USB key
(TinyCore + `tdm on`, SMC keys MVHR/MVMR). That key boots on this iMac, but the SMC toggle was never exercised because no cable
existed; some boards NAK the SMC write (upstream unsolved). So: feasible on paper, 70 % confidence, decided only by the first
test with Cable 1. If the SMC write fails, the direct-cable route is dead for this board and the Ethernet route stays.

## Test when the cable arrives (5 minutes)
1. Boot the iMac from the imac-tdm key (not the DEBLIVE key), connect the cable, Mac mini awake.
2. On the iMac type `tdm on` (or Ctrl+Alt+F2). Picture within 3 s = PASS; "send_byte fail 0x40" in the output = board NAK, FAIL.
3. On PASS: Mac mini System Settings -> Displays shows "iMac" at 2560x1440; set Extend; Sound output "iMac".

## RESULT 2026-11-02 19:3x — PASS: picture on the iMac panel via the direct cable
- Cable: USB-C/Thunderbolt -> Mini DisplayPort, Mac mini M6 REAR middle Thunderbolt port (lightning icon). Front USB-C ports have no DP.
- Key: imac-tdm TinyCore stick (second 16 GB stick, written 18:44). SMC accepted MVHR/MVMR on this board (no 0x40 NAK).
- ORDER MATTERS: `tdm on` with the cable UNPLUGGED, then plugging = black panel but the Mac mini drops the sink in 200 ms (ioreg AppleATCDPAltModePort atc0 EventLog: SinkActive 1 -> 0, SetHints Valid=No). Fix = cable attached first, then Ctrl+Alt+F4 Enter (off), Ctrl+Alt+F3 Enter (on) -> picture within 10 s.
- Resolution: 2560x1440 is the panel native maximum. Brightness: macOS cannot drive the iMac backlight in TDM; use the key: Ctrl+Alt+F6 (100>70>40) or `tdm bright <0-100>` on the iMac console.
- OpenDisplay sender on the Mac mini was parked with macmini/od-pause.sh (backup ~/od-backup/20261102-184823); `od-pause.sh resume` restores the Ethernet route. DEBLIVE key untouched.
- Open: audio to iMac speakers, auto `tdm on` at boot only after cable present (hotplug-aware service), merge TDM as 2nd GRUB profile on DEBLIVE.
