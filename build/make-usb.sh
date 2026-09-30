#!/usr/bin/env bash
# Write wipestick to a USB stick as a FAT32 UEFI drive with a writable
# wipelogs/ folder (erase reports survive reboot and can be read on any PC).
#
# Usage: sudo ./build/make-usb.sh wipestick.iso /dev/sdX
# Needs: gdisk dosfstools xorriso mtools
#
# For legacy-BIOS-only machines, write the ISO raw instead
#   (dd if=wipestick.iso of=/dev/sdX bs=4M conv=fsync)
# which boots BIOS and UEFI but keeps logs only in RAM unless a second
# partition labelled WIPELOGS is added.
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
export MTOOLS_SKIP_CHECK=1
ISO=${1:?usage: make-usb.sh wipestick.iso /dev/sdX}
DEV=${2:?usage: make-usb.sh wipestick.iso /dev/sdX}

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f $ISO ]] || { echo "no such ISO: $ISO" >&2; exit 1; }
[[ $(lsblk -dno TYPE "$DEV" 2>/dev/null) == disk || ${FORCE:-0} == 1 ]] || { echo "$DEV is not a whole disk" >&2; exit 1; }
if [[ $(lsblk -dno TRAN "$DEV" | tr -d ' ') != usb && ${FORCE:-0} != 1 ]]; then
  echo "$DEV is not a USB device. Set FORCE=1 if you are sure." >&2; exit 1
fi

lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINTS "$DEV"
read -rp "Everything on $DEV will be destroyed. Type the device name ($DEV) to continue: " ans
[[ $ans == "$DEV" ]] || { echo "aborted"; exit 1; }

for p in $(lsblk -nrpo NAME "$DEV" | tail -n +2); do umount "$p" 2>/dev/null || true; done
wipefs -a -f "$DEV" >/dev/null
sgdisk --zap-all "$DEV" >/dev/null
sgdisk -n1:0:0 -t1:ef00 -c1:WIPESTICK "$DEV" >/dev/null
partprobe "$DEV"; udevadm settle
PART=$(lsblk -nrpo NAME "$DEV" | sed -n 2p)
mkfs.vfat -F 32 -n WIPESTICK "$PART" >/dev/null

TREE=$(mktemp -d)
trap 'rm -rf "$TREE"' EXIT
echo "copying..."
# xorriso + mtools: no iso9660/vfat kernel mounts needed on the build host.
xorriso -osirrox on -indev "$ISO" -extract / "$TREE" 2>/dev/null
mkdir -p "$TREE/wipelogs"
mcopy -s -i "$PART" "$TREE"/* "$TREE"/.disk ::/
sync
echo "done: $DEV is ready (UEFI, Secure Boot compatible). Reports will be saved to wipelogs/."
