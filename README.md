# wipestick

A bootable USB that erases every internal drive in a PC and leaves it ready for a fresh OS install. It uses the drive's own firmware erase commands first, so SSDs and NVMe drives get almost no wear. All components are open source (GPL-3.0-or-later for this project; Ubuntu packages under their own licenses).

## How it works

1. Boot the stick. A menu lists internal drives. The USB stick itself and any USB drives are never listed.
2. Pick drives, review the plan, type `ERASE`.
3. For each drive, methods are tried in order until one is **verified**:

| Drive | Methods, in order |
|---|---|
| NVMe | Sanitize crypto erase → Sanitize block erase → Format SES=2 (crypto) → Format SES=1 → TRIM → zero pass |
| SATA SSD | ATA Sanitize crypto scramble → ATA Sanitize block erase → ATA Security Erase (enhanced if supported) → TRIM → zero pass |
| HDD | Single zero pass (NIST 800-88 Clear) |
| eMMC | Secure erase/trim → TRIM → zero pass |

4. **Verification:** before erasing, 16 random 4 KiB "canary" blocks are written across the drive. After erasing, each is read back. The method only counts as successful if every canary is gone. If not, the next method runs.
5. Partition tables and filesystem signatures are wiped (`wipefs`, `sgdisk --zap-all`). The disk is blank; Windows or Linux installers take it as-is.
6. A JSON-lines report (host model/serial, drive model/serial, method, result) and a full log are saved to `wipelogs/` on the stick.

## Build

On Ubuntu 24.04 or Debian 12+ as root:

```bash
apt install debootstrap squashfs-tools xorriso mtools dosfstools gdisk grub-pc-bin grub-common
sudo ./build/build-iso.sh            # -> wipestick.iso (~350 MB, about 5 minutes)
sudo ./build/make-usb.sh wipestick.iso /dev/sdX
```

`make-usb.sh` creates a FAT32 UEFI stick with a writable `wipelogs/` folder. Rufus in "ISO image mode" on Windows produces an equivalent stick.
Writing the ISO raw (`dd`, balenaEtcher) also works and adds legacy-BIOS boot, but logs then live in RAM only.

## Boot menu

- **erase drives**: default. Uses `nomodeset` (basic framebuffer), which works on nearly all UEFI machines without GPU firmware.
- **run from RAM**: copies the system to memory. Use it if the stick is flaky after the SATA unfreeze suspend.
- **graphics drivers enabled**: use it if the screen stays blank with the default entry.
- **Firmware setup**: reboots into UEFI setup (to switch RAID/VMD to AHCI, for example).

## Known limits and fixes

- **Secure Boot:** works via Canonical's signed shim. On Snapdragon/ARM PCs and some Secured-core laptops the third-party UEFI CA is off by default; enable "Allow Microsoft 3rd-party UEFI CA" or disable Secure Boot.
- **Intel RST/VMD or RAID mode:** drives may be hidden or reject erase commands. Switch storage mode to AHCI in firmware setup.
- **Frozen SATA drives:** the tool suspends the machine for 6 seconds to unfreeze them. If that fails (common on desktops with s2idle-only sleep), hot-plug the drive's SATA power after boot, or use another port.
- **Self-encrypting drives (Opal) with locking enabled / ATA-password-locked drives:** reported as failed with a hint. Fix with a PSID revert using the PSID printed on the drive label (`sedutil-cli --PSIDrevert`; not bundled yet).
- **Not touched by any disk wipe:** BIOS/UEFI passwords, Absolute/Computrace, and **Autopilot/Intune registration**. Deregister devices in Intune before disposal or reassignment, or they will re-enroll at OOBE.
- **Sanitize is controller-wide:** on NVMe controllers with several namespaces, all of them are erased. The plan screen warns about this.
- **Sanitize survives power loss:** if a machine is powered off mid-sanitize, the drive resumes it at next power-on. That is expected.
- x86-64 only. Macs and ARM are out of scope for now.

## CLI

```
wipestick list
wipestick plan /dev/nvme0n1
wipestick --dry-run erase --confirm ERASE /dev/nvme0n1 /dev/sda
wipestick erase --confirm ERASE /dev/nvme0n1
```

The TUI starts automatically on tty1. Choose "Drop to a root shell" from its end menu for manual work.

## Project layout

```
src/wipestick          erase engine (bash)
src/wipestick-tui      whiptail front end
overlay/               files copied into the live system (systemd unit)
build/build-iso.sh     builds the hybrid ISO
build/make-usb.sh      writes a FAT32 UEFI stick with persistent logs
```

## Test status

Tested in QEMU (no real hardware yet):

| Test | Result |
|---|---|
| UEFI boot with Secure Boot enforced (OVMF, Microsoft keys) from FAT32 USB | Pass |
| Legacy BIOS boot of the raw ISO from a SATA disk | Pass |
| Boot medium excluded from the drive list (both USB and SATA boot) | Pass |
| NVMe Format SES=1, verified by canaries | Pass |
| SATA TRIM that silently did nothing, caught by canaries, fell back to zero pass | Pass |
| Wrong confirmation text erases nothing | Pass |
| Reports persisted to `wipelogs/` on the stick | Pass |

**Not yet tested on real drives:** NVMe Sanitize, NVMe crypto Format, ATA Sanitize, ATA Security Erase, and the suspend-to-unfreeze step. QEMU does not emulate these. Test them on a few spare machines before relying on the tool, and start with `--dry-run` from the root shell.

## Roadmap ideas

- Bundle `sedutil-cli` for Opal detection and guided PSID revert.
- Hot-plug helper for frozen SATA drives.
- Optional unattended "bench mode" (countdown) as a separate boot entry.
- arm64 build for specific Snapdragon models.
- PDF/CSV certificate export from the JSON report.
