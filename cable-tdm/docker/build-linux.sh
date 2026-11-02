#!/bin/sh
# Runs inside a debian container (see build.sh). Produces in /out:
#   SmcDumpKey   - static x86_64 Linux binary (SMC port-I/O tool, floe/smc_util)
#   BOOTX64.EFI  - standalone GRUB2 EFI loader with /in/grub.cfg embedded
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -qq -y --no-install-recommends gcc libc6-dev grub-efi-amd64-bin grub-common file >/dev/null

gcc -O2 -static -Wall -o /out/SmcDumpKey /in/smc_util/SmcDumpKey.c
file /out/SmcDumpKey

grub-mkstandalone -O x86_64-efi -o /out/BOOTX64.EFI \
    --modules="part_gpt part_msdos fat search search_label search_fs_uuid linux normal configfile echo sleep test all_video gfxterm efi_gop efi_uga" \
    "boot/grub/grub.cfg=/in/grub.cfg"

ls -la /out
