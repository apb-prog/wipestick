#!/usr/bin/env bash
# Boot a wipestick ISO in QEMU and run the built-in self-test.
#
# Usage: tests/qemu-selftest.sh wipestick.iso [uefi-sb|bios] [workdir]
#   uefi-sb  OVMF with Secure Boot enforced (Microsoft keys), ISO as a USB stick
#   bios     SeaBIOS, ISO written raw to a SATA disk (tests boot-disk exclusion)
#
# Pass criteria: serial log shows WIPESTICK-SELFTEST-PASS and both test
# drives (NVMe + SATA, filled with random data and partitions) read back as
# all zeros after the VM powers itself off.
#
# Needs: qemu-system-x86 ovmf gdisk (KVM optional; TCG is ~5x slower)
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2054  # commas are QEMU option syntax, not array separators
set -euo pipefail

ISO=$(readlink -f "${1:?usage: qemu-selftest.sh wipestick.iso [uefi-sb|bios] [workdir]}")
MODE=${2:-uefi-sb}
WORK=${3:-$(mktemp -d)}
TIMEOUT=${TIMEOUT:-1200}
SIZE=1G
mkdir -p "$WORK"; cd "$WORK"

mkdisk() {
  rm -f "$1"; truncate -s "$SIZE" "$1"
  sgdisk -n1:0:+300M -t1:0700 -n2:0:0 -t2:8300 "$1" >/dev/null
  dd if=/dev/urandom of="$1" bs=1M seek=2 count=400 conv=notrunc status=none
}
mkdisk nvme.img
mkdisk sata.img

ACCEL=(-accel tcg -cpu max)
[[ -w /dev/kvm ]] && ACCEL=(-accel kvm -cpu host)

COMMON=(
  -machine q35,smm=on "${ACCEL[@]}" -smp 2 -m 3072
  -smbios type=11,value=wipestick-selftest
  -drive file=nvme.img,if=none,id=nv,format=raw -device nvme,drive=nv,serial=WSTEST-NVME
  -device ahci,id=ahci
  -drive file=sata.img,if=none,id=sd,format=raw -device ide-hd,drive=sd,bus=ahci.0,serial=WSTEST-SATA,rotation_rate=1
  -display none -serial file:serial.log -no-reboot
)

case $MODE in
  uefi-sb)
    CODE=$(ls /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd 2>/dev/null | head -n1 || true)
    VARS=$(ls /usr/share/OVMF/OVMF_VARS_4M.ms.fd /usr/share/OVMF/OVMF_VARS.ms.fd 2>/dev/null | head -n1 || true)
    [[ -n $CODE && -n $VARS ]] || { echo "OVMF Secure Boot firmware not found (install ovmf)"; exit 2; }
    cp "$VARS" vars.fd
    cp "$ISO" boot.img
    BOOT=(
      -global driver=cfi.pflash01,property=secure,value=on
      -drive if=pflash,format=raw,unit=0,file="$CODE",readonly=on
      -drive if=pflash,format=raw,unit=1,file=vars.fd
      -device qemu-xhci -drive file=boot.img,if=none,id=usb,format=raw
      -device usb-storage,drive=usb,removable=on,serial=WSBOOT-USB,bootindex=0
    )
    ;;
  bios)
    cp "$ISO" boot.img
    BOOT=(-drive file=boot.img,if=none,id=bd,format=raw -device ide-hd,drive=bd,bus=ahci.1,serial=WSBOOT-SATA,bootindex=0)
    ;;
  *) echo "unknown mode $MODE"; exit 2 ;;
esac

rm -f serial.log
echo "booting ($MODE, ${ACCEL[1]}), timeout ${TIMEOUT}s, work dir $WORK"
set +e
timeout "$TIMEOUT" qemu-system-x86_64 "${COMMON[@]}" "${BOOT[@]}"
qrc=$?
set -e
echo "----- serial log -----"; cat serial.log 2>/dev/null; echo "----------------------"

result=0
if (( qrc == 124 )); then echo "FAIL: VM did not power off within ${TIMEOUT}s"; result=1; fi
grep -q WIPESTICK-SELFTEST-PASS serial.log 2>/dev/null || { echo "FAIL: self-test did not report PASS"; result=1; }
for img in nvme.img sata.img; do
  if cmp -s -n "$(stat -c %s "$img")" "$img" /dev/zero; then echo "ok: $img is all zeros"
  else echo "FAIL: $img still contains data"; result=1; fi
done
(( result == 0 )) && echo "SELFTEST $MODE: PASS" || echo "SELFTEST $MODE: FAIL"
exit "$result"
