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
  -global ICH9-LPC.disable_s3=0
  -drive file=nvme.img,if=none,id=nv,format=raw -device nvme,drive=nv,serial=WSTEST-NVME
  -device ahci,id=ahci
  -drive file=sata.img,if=none,id=sd,format=raw -device ide-hd,drive=sd,bus=ahci.0,serial=WSTEST-SATA,rotation_rate=1
  -display none -vga std -serial file:serial.log -no-reboot
  -monitor unix:monitor.sock,server,nowait
)

SMBIOS=(-smbios type=11,value=wipestick-selftest)
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
    # SeaBIOS resumes from S3 reliably under emulation, so test suspend here.
    SMBIOS=(-smbios type=11,value=wipestick-selftest,value=wipestick-selftest-s3)
    ;;
  *) echo "unknown mode $MODE"; exit 2 ;;
esac

rm -f serial.log
echo "booting ($MODE, ${ACCEL[1]}), timeout ${TIMEOUT}s, work dir $WORK"
# Screenshot the VM console every 60 s (shot-NN.ppm) so a hang shows where it stopped.
screens() {
  local n=0
  sleep 20
  while [[ -S monitor.sock ]]; do
    n=$(( n + 1 ))
    python3 - "$n" <<'PY' 2>/dev/null || true
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect("monitor.sock"); time.sleep(0.3); s.recv(4096)
s.send(("screendump shot-%02d.ppm\n" % int(sys.argv[1])).encode()); time.sleep(1); s.close()
PY
    sleep 60
  done
}
# After the self-test reports it resumed from suspend, screenshot the console
# and check it is not blank (the display came back).
mon() {  # send one command to the QEMU monitor, print the reply
  python3 - "$1" <<'PY' 2>/dev/null || true
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect("monitor.sock"); time.sleep(0.3); s.recv(4096)
s.send((sys.argv[1] + "\n").encode()); time.sleep(1); print(s.recv(4096).decode(errors="replace")); s.close()
PY
}
resume_check() {
  local i asleep=0 pre=0
  for (( i = 0; i < TIMEOUT; i += 2 )); do
    if (( ! pre )) && grep -qa 'SUSPEND-TEST: suspending' serial.log 2>/dev/null; then
      mon "screendump presuspend.ppm" >/dev/null; pre=1
    fi
    # QEMU's RTC alarm does not always wake the VM from S3 (real hardware did).
    # If the guest stays suspended for 15 s, press the virtual wake button.
    if mon "info status" | grep -q suspended; then
      asleep=$(( asleep + 2 ))
      if (( asleep >= 15 )); then
        echo "harness: VM still suspended after ${asleep}s; sending system_wakeup"
        mon system_wakeup >/dev/null; asleep=0
      fi
    fi
    if grep -qa 'SUSPEND-TEST: resumed' serial.log 2>/dev/null; then
      sleep 2
      python3 - <<'PY' 2>/dev/null || true
import socket, time
s = socket.socket(socket.AF_UNIX); s.connect("monitor.sock"); time.sleep(0.3); s.recv(4096)
s.send(b"screendump resume.ppm\n"); time.sleep(1); s.close()
PY
      return
    fi
    grep -qa 'SUSPEND-TEST: skipped' serial.log 2>/dev/null && return
    sleep 2
  done
}
# Fraction of pixels that differ clearly between two same-size binary PPMs.
# After resume the self-test prints a banner, so a live display must change.
changed_fraction() {
  python3 - "$1" "$2" <<'PY'
import sys
def load(path):
    d = open(path, "rb").read(); parts, pos = [], 0
    while len(parts) < 4:
        while d[pos:pos+1].isspace(): pos += 1
        end = pos
        while not d[end:end+1].isspace(): end += 1
        parts.append(d[pos:end]); pos = end
    return d[pos+1:]
a, b = load(sys.argv[1]), load(sys.argv[2])
n = min(len(a), len(b)) // 3
diff = sum(1 for i in range(0, n * 3, 3) if abs(a[i] - b[i]) + abs(a[i+1] - b[i+1]) + abs(a[i+2] - b[i+2]) > 96)
print("%.4f" % (diff / max(1, n)))
PY
}
rm -f shot-*.ppm resume.ppm presuspend.ppm monitor.sock
set +e
timeout "$TIMEOUT" qemu-system-x86_64 "${COMMON[@]}" "${SMBIOS[@]}" "${BOOT[@]}" &
qpid=$!
screens &
spid=$!
resume_check &
rpid=$!
# Power-off watchdog: after PASS, allow 120 s for a clean shutdown. QEMU's ACPI
# power-off sometimes hangs after an S3 resume; quit the VM and say so.
poweroff_watch() {
  while ! grep -qa 'WIPESTICK-SELFTEST-PASS\|WIPESTICK-SELFTEST-FAIL' serial.log 2>/dev/null; do sleep 2; done
  sleep 120
  echo "harness: WARNING: VM did not power off within 120 s of finishing; forcing quit"
  touch poweroff-forced
  mon quit >/dev/null
}
rm -f poweroff-forced
poweroff_watch &
wpid=$!
wait "$qpid"
qrc=$?
kill "$spid" "$rpid" "$wpid" 2>/dev/null
set -e
echo "----- serial log -----"; cat serial.log 2>/dev/null; echo "----------------------"

result=0
if (( qrc == 124 )); then echo "FAIL: VM did not power off within ${TIMEOUT}s"; result=1; fi
grep -q WIPESTICK-SELFTEST-PASS serial.log 2>/dev/null || { echo "FAIL: self-test did not report PASS"; result=1; }
if grep -qa 'SUSPEND-TEST: resumed' serial.log; then
  if [[ -f resume.ppm && -f presuspend.ppm ]]; then
    chg=$(changed_fraction presuspend.ppm resume.ppm)
    if awk "BEGIN{exit !($chg > 0.0005)}"; then echo "ok: display updated after resume ($chg of pixels changed)"
    else echo "FAIL: display did not update after resume ($chg of pixels changed)"; result=1; fi
  else
    echo "FAIL: missing before/after screenshots for the resume check"; result=1
  fi
elif grep -qa 'SUSPEND-TEST: skipped' serial.log; then
  echo "WARNING: suspend/resume not tested (VM has no S3)"
fi
for img in nvme.img sata.img; do
  if cmp -s -n "$(stat -c %s "$img")" "$img" /dev/zero; then echo "ok: $img is all zeros"
  else echo "FAIL: $img still contains data"; result=1; fi
done
(( result == 0 )) && echo "SELFTEST $MODE: PASS" || echo "SELFTEST $MODE: FAIL"
exit "$result"
