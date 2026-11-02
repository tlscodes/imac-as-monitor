#!/bin/bash
# display-off.sh — runs ON the Mac mini. Puts its displays to sleep right now;
# every background job keeps running (system sleep is a separate pmset setting).
#
# Why this is the whole feature: the iMac in Target Display Mode is a plain
# DisplayPort sink. No signal -> panel and backlight off (lowest power the iMac
# can reach while staying "booted"); first mouse/keyboard event on the mini ->
# signal back -> picture back in ~2 s. Nothing reboots, nothing toggles TDM:
# tdm-guard on the iMac polls only the SMC flag MVHR, never the link state.
#
# One-time setting on the mini so the system itself never sleeps (needs sudo):
#   sudo pmset -c sleep 0 displaysleep 10
exec /usr/bin/pmset displaysleepnow
