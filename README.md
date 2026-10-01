# wipestick

A bootable USB that erases every internal drive in a PC and leaves it ready for a fresh OS install. It uses the drive's own firmware erase commands first, so SSDs and NVMe drives get almost no wear. All components are open source (GPL-3.0-or-later for this project; Debian packages under their own licenses).

## How it works

1. Boot the stick. A menu lists internal drives. The USB stick itself and any USB drives are never listed.
2. Pick drives, review the plan, type `ERASE`.
3. For each drive, methods are tried in order until one is **verified**:

| Drive | Methods, in order |
|---|---|
| NVMe | Sanitize crypto erase → Sanitize block erase → Format SES=2 (crypto) → Format SES=1 → zero pass + TRIM |
| SATA SSD | ATA Sanitize crypto scramble → ATA Sanitize block erase → ATA Security Erase (enhanced if supported) → zero pass + TRIM |
| HDD | Single zero pass (NIST 800-88 Clear) |
| eMMC | Secure erase/trim → zero pass + TRIM |

4. **Verification:** before erasing, 16 random 4 KiB "canary" blocks are written across the drive. After erasing, each is read back. The method only counts as successful if every canary is gone. If not, the next method runs.
5. Each result is graded: **Purge** (firmware erase of the whole drive), **Clear** (every block overwritten once; SSD spare areas not reached), or **Logical** (TRIM only, no longer used as a final step).
   **Stalls:** a firmware sanitize reports progress as a counter out of 65,535, so a working drive moves it every few seconds. If it does not move for 5 minutes (30 for hard drives), WipeStick gives up on that method. If the drive has left the sanitize, the next method runs; if it is still busy with it, the drive refuses everything else until it loses power, so WipeStick stops on that drive. The summary button then reads "Press Enter to Power Off", and the menu after it offers no Reboot or Start over (a reboot usually keeps the drive powered); boot WipeStick again after the machine is off. Stalled methods are recorded in `wipelogs/stalled-drives.txt` (by drive serial) and skipped on later runs; delete a line to try that method again. A sanitize still running from an earlier attempt (it survives reboots) is waited for before anything else.
   **Stopping:** Ctrl+C during an erase stops WipeStick and shows a "Process interrupted by user" summary. Drives marked INTERRUPTED or NOT STARTED are not erased. A firmware erase that has already started keeps running inside the drive.
   On any failure, stall or interruption, the summary shows each drive's current sanitize status.
6. Partition tables and filesystem signatures are wiped (`wipefs`, `sgdisk --zap-all`). The disk is blank; Windows or Linux installers take it as-is.
7. A JSON-lines report (host model/serial, drive model/serial, method, result) and a full log are saved to `wipelogs/` on the stick.

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

Both images boot the default entry after 5 seconds.

- **WipeStick (default):** loads Intel's graphics driver (i915), which gives native resolution and restores the display after the suspend used to unfreeze SATA drives. The AMD, NVIDIA and newer Intel `xe` drivers are blocked (`module_blacklist=amdgpu,radeon,nouveau,xe`), because without non-free firmware they can leave the screen black. Those machines use the basic firmware display instead. It works, but stays dark after a suspend, so only then does WipeStick warn about it and power off by itself 60 seconds after finishing.
- **WipeStick (safe graphics):** `nomodeset` for everything. Use it if the screen goes black at boot.
- The console font is picked at startup: the largest Terminus font that still gives at least 100x30 characters.
- To run from RAM on the Debian image, press `e` (GRUB) or `Tab` (syslinux) and add `toram`. The Ubuntu image has it as a menu entry.
- Boot and shutdown are kept quiet (`quiet loglevel=3 systemd.show_status=false systemd.log_level=crit`), so the harmless "Failed unmounting" messages from the live medium at power-off are not shown. The trade-off: systemd's own error messages are not logged either.

### Branding

`live/branding/splash.png` (1920x1080) is the GRUB/UEFI background, and `splash-bios.png` (640x480) is the syslinux/BIOS one, with the logo kept above the menu rows. The build hook `live/config/hooks/normal/9200-branding.hook.binary` installs them, asks GRUB for 1920x1080 (falling back to the panel's own mode), and renames the menu entries. Custom GRUB fonts are not used: signed GRUB refuses to load font files under Secure Boot, so the menu uses GRUB's built-in 16-pixel font.

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
wipestick diag            # saves hardware details to wipelogs/ (also on the end menu)
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

`tests/qemu-selftest.sh wipestick.iso uefi-sb|bios` boots the image in QEMU with an NVMe drive and a SATA drive full of random data and partitions. The live system runs `wipestick-selftest`, which erases the test drives and powers off. In `bios` mode it first suspends and resumes the VM (the same path as the SATA unfreeze), and the harness checks that the screen updated after resume. That check doesn't run in `uefi-sb` mode because QEMU's UEFI firmware hangs on resume under emulation; real UEFI machines are not affected. The test passes when the log shows PASS, both drives read back as all zeros, and the boot disk was not listed.

The self-test only runs when the VM's SMBIOS OEM strings contain `wipestick-selftest`, and it only erases drives whose serial starts with `WSTEST`. Real hardware never matches either, so on a real machine the service does nothing.

## Test status

Tested in QEMU:

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

**First real-hardware run (Dell OptiPlex 3030 AIO, SanDisk X300 128 GB SATA SSD, v0.1.0):** ATA Sanitize was rejected by the drive (hdparm still reported it as started; the canaries caught it). The firmware had the drive frozen; suspend/resume unfroze it, and ATA Security Erase (enhanced) completed and verified 16/16 in about 9 minutes. The display did not come back after resume because v0.1.0 booted with `nomodeset`; v0.1.2 loads the Intel graphics driver by default to fix this (not yet confirmed on that machine).

**Second real-hardware run (Lenovo ThinkPad X1 Carbon 6th gen, Intel SSDPEKKF256G8L NVMe, v0.1.2):** the drive offers no Sanitize, and rejected NVMe Format (SES=2 and SES=1) with Command Sequence Error. That held after a suspend/resume, and its TCG Opal locking was off, so the cause is still unknown. v0.1.2 fell back to TRIM; v0.1.3 falls back to a zero pass plus TRIM (Clear) instead, and records the drive's Opal state.

**Third real-hardware run (same OptiPlex 3030 AIO and SanDisk X300, v0.1.4, legacy BIOS boot):** this time the drive accepted ATA Sanitize (block erase), but its progress counter sat at 0x5b (0%) for over 7 minutes until the operator stopped it. The partitions were still readable after a reboot, so nothing had been erased. v0.1.5 adds stall detection, skips a stalled method on later runs, and handles Ctrl+C with a summary screen. The stall, skip and interrupt paths were tested against a simulated drive replaying this one's responses; the fix has not been run on the machine yet.

**Not yet tested on real drives:** NVMe Sanitize, NVMe crypto Format, and a successful ATA Sanitize. QEMU does not emulate these. Test them on a few spare machines before relying on the tool, and start with `--dry-run` from the root shell.

## Roadmap ideas

- Bundle `sedutil-cli` for Opal detection and guided PSID revert.
- Hot-plug helper for frozen SATA drives.
- Optional unattended "bench mode" (countdown) as a separate boot entry.
- arm64 build for specific Snapdragon models.
- PDF/CSV certificate export from the JSON report.
