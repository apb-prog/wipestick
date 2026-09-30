#!/usr/bin/env bash
# Build the wipestick live ISO on Debian with live-build.
#
# Requirements (Debian 13 "trixie" host, VM, WSL2, or container run with
# --privileged; run as root):
#   apt install live-build
#
# Usage: sudo ./build/build-debian.sh [output.iso]
# Env:   WIPESTICK_SUITE=trixie   Debian release to build from
#        WIPESTICK_MIRROR=URL     Debian mirror (default deb.debian.org)
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/wipestick-debian.iso}
LIVE=$ROOT/live

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
command -v lb >/dev/null || { echo "live-build not installed: apt install live-build" >&2; exit 1; }

echo "==> syncing wipestick files into the live-build tree"
INC=$LIVE/config/includes.chroot
rm -rf "$INC"
mkdir -p "$INC/usr/local/sbin"
cp -a "$ROOT/overlay/." "$INC/"
install -m 0755 "$ROOT/src/wipestick"     "$INC/usr/local/sbin/wipestick"
install -m 0755 "$ROOT/src/wipestick-tui" "$INC/usr/local/sbin/wipestick-tui"
chmod 0755 "$INC/usr/local/sbin/"*

MIRROR_ARGS=()
if [[ -n ${WIPESTICK_MIRROR:-} ]]; then
  MIRROR_ARGS=(--mirror-bootstrap "$WIPESTICK_MIRROR" --mirror-chroot "$WIPESTICK_MIRROR" --mirror-binary "$WIPESTICK_MIRROR")
fi

cd "$LIVE"
echo "==> lb clean / config / build"
lb clean --purge >/dev/null 2>&1 || true
lb config "${MIRROR_ARGS[@]}"
lb build

ISO=$(ls -1 "$LIVE"/*.hybrid.iso 2>/dev/null | head -n1)
[[ -f $ISO ]] || { echo "build finished but no ISO found; see live/build.log" >&2; exit 1; }
mv "$ISO" "$OUT"
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
