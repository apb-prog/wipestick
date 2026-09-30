# wipestick

A bootable USB that erases every internal drive in a PC and leaves it ready for a fresh OS install. It uses the drive's own firmware erase commands first, so SSDs and NVMe drives get almost no wear. All components are open source (GPL-3.0-or-later for this project; Debian packages under their own licenses).

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

The primary build is **Debian 13 (trixie) with live-build**. There are two ways to run it.

**GitHub Actions (recommended).** Push this repo to GitHub. `.github/workflows/build.yml` lints the scripts, builds the ISO in a `debian:trixie` container, boot-tests it in QEMU (UEFI with Secure Boot enforced, and legacy BIOS), and uploads the ISO as a build artifact. Pushing a tag like `v0.2.0` also publishes it as a GitHub Release.

**Any Debian machine** (VM, WSL2, or a container run with `--privileged`), as root:

```bash
apt install live-build
sudo ./build/build-debian.sh          # -> wipestick-debian.iso
```

**Ubuntu alternative:** `build/build-ubuntu.sh` builds an Ubuntu 24.04 image with a newer (HWE) kernel, for very new hardware. It needs `debootstrap squashfs-tools xorriso mtools dosfstools gdisk grub-pc-bin grub-common`.

**Write a stick:**

```bash
sudo ./build/make-usb.sh wipestick-debian.iso /dev/sdX
```

`make-usb.sh` creates a FAT32 UEFI stick with a writable `wipelogs/` folder. Rufus in "ISO image mode" on Windows produces an equivalent stick. Writing the ISO raw (`dd`, balenaEtcher, Rufus "DD mode") also works and adds legacy-BIOS boot, but logs then live in RAM only.

## Boot menu

The Debian image uses live-build's standard menus (GRUB on UEFI, syslinux on BIOS), set by a build hook to boot the default entry after 5 seconds. The default entry boots with `nomodeset` (basic framebuffer), which works on nearly all machines without GPU firmware. To run from RAM, press `e` (GRUB) or `Tab` (syslinux) and add `toram`. The Ubuntu image has these as separate menu entries, plus a firmware-setup entry.

## Known limits and fixes

- **Secure Boot:** works via the distribution's Microsoft-signed shim (Debian's or Canonical's). Microsoft's 2011 third-party signing certificate expired in June 2026; test on your oldest machines with Secure Boot on. On Snapdragon/ARM PCs and some Secured-core laptops the third-party UEFI CA is off by default; enable "Allow Microsoft 3rd-party UEFI CA" or disable Secure Boot.
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

The TUI starts automatically on tty1. Choose "Drop to a root shell" from its end menu for manual work. On the Debian image, tty2-tty6 also offer a login as `user` / password `live` (live-config defaults; `sudo` works).

## Project layout

```
src/wipestick                erase engine (bash)
src/wipestick-tui            whiptail front end
overlay/                     files copied into the live system (systemd units, self-test)
live/                        Debian live-build config (auto/, package list, hook)
build/build-debian.sh        builds the Debian ISO (primary)
build/build-ubuntu.sh        builds the Ubuntu ISO (alternative, newer kernel)
build/make-usb.sh            writes a FAT32 UEFI stick with persistent logs
tests/qemu-selftest.sh       boots an ISO in QEMU and runs the self-test
.github/workflows/build.yml  CI: lint, build, boot-test, release
```

## Self-test

`tests/qemu-selftest.sh wipestick.iso uefi-sb|bios` boots the image in QEMU with an NVMe drive and a SATA drive full of random data and partitions. The live system runs `wipestick-selftest`, which erases the test drives and powers off. The test passes when the log shows PASS, both drives read back as all zeros, and the boot disk was not listed.

The self-test only runs when the VM's SMBIOS OEM strings contain `wipestick-selftest`, and it only erases drives whose serial starts with `WSTEST`. Real hardware never matches either, so on a real machine the service does nothing.

## Test status

Tested in QEMU (no real hardware yet):

| Test | Ubuntu (casper) | Debian boot path (live-boot)* | Debian build (live-build) |
|---|---|---|---|
| UEFI boot, Secure Boot enforced, from USB | Pass | Pass | Pass |
| Legacy BIOS boot, raw ISO on a SATA disk | Pass | Pass | Pass |
| Boot medium excluded from the drive list | Pass | Pass | Pass |
| NVMe Format SES=1, verified by canaries | Pass | Pass | Pass |
| TRIM that did nothing, caught, fell back to zero pass | Pass | Pass | Pass |
| Reports persisted to `wipelogs/` on a FAT32 stick | Pass | Pass | Not yet run |
| Wrong confirmation text erases nothing | Pass | Not run | Not yet run |

\* An Ubuntu build using Debian's live-boot (`LIVEBOOT=1 build/build-ubuntu.sh`). It exercises the same boot and medium-mount path as the Debian image, which could not be built where this was developed.

**Not yet tested on real drives:** NVMe Sanitize, NVMe crypto Format, ATA Sanitize, ATA Security Erase, and the suspend-to-unfreeze step. QEMU does not emulate these. Test them on a few spare machines before relying on the tool, and start with `--dry-run` from the root shell.

## Roadmap ideas

- Bundle `sedutil-cli` for Opal detection and guided PSID revert.
- Hot-plug helper for frozen SATA drives.
- Optional unattended "bench mode" (countdown) as a separate boot entry.
- arm64 build for specific Snapdragon models.
- PDF/CSV certificate export from the JSON report.
