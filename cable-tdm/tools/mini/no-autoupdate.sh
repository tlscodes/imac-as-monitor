#!/bin/sh
# no-autoupdate.sh — run ON the Mac mini, once, with sudo:   sudo ~/od-sender/no-autoupdate.sh
# Why: macOS auto-installed 27.2 and rebooted the mini at 02:09 on 2026-11-03; after a mini reboot the
# DisplayPort link to the iMac stays "No Link" until the iMac does TDM off/on. The link-watch agent now
# repairs that, but a monitor-driver box must not reboot on its own at all. Verified: the three keys read 0
# afterwards (`defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates`);
# "Automatic checking" may still print "on" — it only notifies, it never installs or reboots.
set -e
softwareupdate --schedule off
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
echo "DONE: auto-update OFF"
