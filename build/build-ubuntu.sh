#!/usr/bin/env bash
# Build the wipestick live ISO (Ubuntu 24.04 base, UEFI + legacy BIOS,
# Secure Boot via Canonical's Microsoft-signed shim, signed GRUB and kernel).
#
# Requirements on the build host (Ubuntu/Debian, run as root):
#   apt install debootstrap squashfs-tools xorriso mtools dosfstools grub-pc-bin grub-common
#
# Usage: sudo ./build/build-ubuntu.sh [output.iso]
# Env:   LIVEBOOT=1  use Debian's live-boot instead of casper (mirrors the
#                    Debian build's boot path; used to test it without Debian mirrors)
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-$ROOT/work}
OUT=${1:-$ROOT/wipestick.iso}
SUITE=${SUITE:-noble}
MIRROR=${MIRROR:-http://archive.ubuntu.com/ubuntu}
VOLID="WIPESTICK"
CHROOT=$WORK/chroot
IMAGE=$WORK/image

if [[ ${LIVEBOOT:-0} == 1 ]]; then
  LIVEPKG=(live-boot live-boot-initramfs-tools); LIVEDIR=live; BOOTARG="boot=live components noeject"
else
  LIVEPKG=(casper); LIVEDIR=casper; BOOTARG="boot=casper noprompt"
fi
PACKAGES=(
  "${LIVEPKG[@]}" initramfs-tools systemd-sysv udev kmod dbus
  nvme-cli hdparm gdisk parted util-linux dosfstools e2fsprogs
  whiptail jq dmidecode pciutils smartmontools
  lvm2 mdadm cryptsetup-bin
  kbd less nano console-setup-linux
)

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

cleanup() {
  for m in dev/pts dev proc sys run; do umount -lf "$CHROOT/$m" 2>/dev/null || true; done
}
trap cleanup EXIT

in_chroot() { chroot "$CHROOT" /usr/bin/env DEBIAN_FRONTEND=noninteractive LC_ALL=C "$@"; }

echo "==> [1/7] bootstrap $SUITE"
rm -rf "$WORK"; mkdir -p "$CHROOT" "$IMAGE"/{"$LIVEDIR",boot/grub,EFI/BOOT,.disk}
debootstrap --variant=minbase --arch=amd64 --components=main,universe "$SUITE" "$CHROOT" "$MIRROR"

for m in dev dev/pts proc sys run; do mount --bind "/$m" "$CHROOT/$m"; done
cat > "$CHROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main universe
deb $MIRROR $SUITE-updates main universe
deb $MIRROR $SUITE-security main universe
EOF
# Keep apt from pulling docs and recommends into the image.
cat > "$CHROOT/etc/apt/apt.conf.d/99wipestick" <<'EOF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF

echo "==> [2/7] install packages"
in_chroot apt-get update -qq
in_chroot apt-get install -y -qq "${PACKAGES[@]}"

# HWE kernel without the ~600 MB linux-firmware package. The tool only needs
# storage drivers and a text console; boot entries default to nomodeset.
KPKG=$(in_chroot apt-cache depends linux-image-generic-hwe-24.04 | awk '/Depends: linux-image-[0-9]/{print $2; exit}')
KVER=${KPKG#linux-image-}
echo "    kernel: $KVER"
EXTRA=()
in_chroot apt-cache show "linux-modules-extra-$KVER" >/dev/null 2>&1 && EXTRA=("linux-modules-extra-$KVER")
in_chroot apt-get install -y -qq "$KPKG" "${EXTRA[@]}"
# Sanity check: the storage drivers we depend on must be present.
for mod in nvme vmd ahci sd_mod uas usb_storage mmc_block sdhci_pci; do
  in_chroot modinfo -k "$KVER" "$mod" >/dev/null 2>&1 || echo "    WARNING: module $mod not found in $KVER"
done

echo "==> [3/7] configure system"
install -m 0755 "$ROOT/src/wipestick"     "$CHROOT/usr/local/sbin/wipestick"
install -m 0755 "$ROOT/src/wipestick-tui" "$CHROOT/usr/local/sbin/wipestick-tui"
cp -a "$ROOT/overlay/." "$CHROOT/"
echo wipestick > "$CHROOT/etc/hostname"
in_chroot systemctl enable wipestick.service wipestick-selftest.service
in_chroot systemctl mask getty@tty1.service apt-daily.timer apt-daily-upgrade.timer \
  motd-news.timer mdmonitor.service lvm2-monitor.service 2>/dev/null || true
# Never auto-assemble RAID or activate LVM on the drives we are about to erase.
mkdir -p "$CHROOT/etc/mdadm"
sed -i '/^AUTO /d' "$CHROOT/etc/mdadm/mdadm.conf" 2>/dev/null || true
echo "AUTO -all" >> "$CHROOT/etc/mdadm/mdadm.conf"
sed -i 's/# *event_activation = 1/event_activation = 0/' "$CHROOT/etc/lvm/lvm.conf" || true
in_chroot update-initramfs -u -k "$KVER"

echo "==> [4/7] fetch signed boot binaries"
DEBS=$WORK/debs; mkdir -p "$DEBS"
(cd "$DEBS" && in_chroot sh -c "cd /tmp && apt-get download -qq shim-signed grub-efi-amd64-signed" && mv "$CHROOT"/tmp/*.deb .)
for d in "$DEBS"/*.deb; do dpkg-deb -x "$d" "$DEBS/x"; done
SHIM=$(find "$DEBS/x" -name 'shimx64.efi.signed*' | head -n1)
MM=$(find "$DEBS/x" -name 'mmx64.efi' | head -n1)
GCD=$(find "$DEBS/x" -name 'gcdx64.efi.signed' | head -n1)
[[ -f $SHIM && -f $GCD ]] || { echo "signed shim/grub not found" >&2; exit 1; }

echo "==> [5/7] squashfs"
cp "$CHROOT/boot/vmlinuz-$KVER" "$IMAGE/$LIVEDIR/vmlinuz"
cp "$CHROOT/boot/initrd.img-$KVER" "$IMAGE/$LIVEDIR/initrd"
in_chroot apt-get clean
rm -rf "$CHROOT"/var/lib/apt/lists/* "$CHROOT"/tmp/* "$CHROOT"/usr/share/doc/* "$CHROOT"/usr/share/man/*
cleanup
mksquashfs "$CHROOT" "$IMAGE/$LIVEDIR/filesystem.squashfs" -comp zstd -Xcompression-level 19 -noappend -quiet
du -sx --block-size=1 "$CHROOT" | cut -f1 > "$IMAGE/$LIVEDIR/filesystem.size"

echo "==> [6/7] bootloaders"
echo "wipestick $(sed -n 's/^VERSION="\(.*\)"/\1/p' "$ROOT/src/wipestick") ($SUITE amd64) $(date -u +%Y%m%d)" > "$IMAGE/.disk/info"
GFX="module_blacklist=amdgpu,radeon,nouveau,xe"
CMDLINE="$BOOTARG quiet loglevel=3 fsck.mode=skip systemd.show_status=0 systemd.log_level=crit"
cat > "$IMAGE/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0
insmod all_video
menuentry "wipestick - erase drives" {
  linux /$LIVEDIR/vmlinuz $CMDLINE $GFX
  initrd /$LIVEDIR/initrd
}
menuentry "wipestick - erase drives (run from RAM; USB can be removed)" {
  linux /$LIVEDIR/vmlinuz $CMDLINE $GFX toram
  initrd /$LIVEDIR/initrd
}
menuentry "wipestick - safe graphics (nomodeset, if the screen goes black)" {
  linux /$LIVEDIR/vmlinuz $CMDLINE nomodeset
  initrd /$LIVEDIR/initrd
}
menuentry "Firmware setup (UEFI only)" {
  fwsetup
}
EOF

# UEFI: shim (Microsoft-signed) -> grubx64.efi (Canonical-signed, CD build).
cp "$SHIM" "$IMAGE/EFI/BOOT/BOOTX64.EFI"
cp "$GCD"  "$IMAGE/EFI/BOOT/grubx64.efi"
[[ -f $MM ]] && cp "$MM" "$IMAGE/EFI/BOOT/mmx64.efi"
EFIIMG=$WORK/efiboot.img
truncate -s 8M "$EFIIMG"; mkfs.vfat -n WSEFI "$EFIIMG" >/dev/null
mmd -i "$EFIIMG" ::/EFI ::/EFI/BOOT
mcopy -i "$EFIIMG" "$IMAGE"/EFI/BOOT/* ::/EFI/BOOT/

# Legacy BIOS: GRUB El Torito image.
cat > "$WORK/bios-grub.cfg" <<'EOF'
search --no-floppy --set=root --file /.disk/info
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF
grub-mkstandalone --format=i386-pc --output="$WORK/core.img" \
  --install-modules="linux normal iso9660 biosdisk memdisk tar search search_fs_file configfile part_msdos part_gpt fat ls echo test" \
  --modules="linux normal iso9660 biosdisk memdisk tar search search_fs_file configfile" \
  --locales="" --fonts="" --themes="" \
  "boot/grub/grub.cfg=$WORK/bios-grub.cfg"
cat /usr/lib/grub/i386-pc/cdboot.img "$WORK/core.img" > "$IMAGE/boot/grub/bios.img"
cp "$EFIIMG" "$IMAGE/boot/grub/efiboot.img"

echo "==> [7/7] iso"
(cd "$IMAGE" && find . -type f ! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt)
xorriso -as mkisofs -r -iso-level 3 -full-iso9660-filenames -J -joliet-long \
  -volid "$VOLID" -output "$OUT" \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  -partition_offset 16 --mbr-force-bootable \
  -append_partition 2 0xef "$EFIIMG" -appended_part_as_gpt \
  -c boot/grub/boot.cat \
  -b boot/grub/bios.img -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot -e '--interval:appended_partition_2:all::' -no-emul-boot \
  "$IMAGE"
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
