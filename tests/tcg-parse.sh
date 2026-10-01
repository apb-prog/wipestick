#!/usr/bin/env bash
# Parse a real TCG Level 0 response (Intel SSDPEKKF256G8L, ThinkPad X1 Carbon)
# with and without the status line some nvme-cli versions print before the
# raw bytes. Both must decode the same way.
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
cd "$(dirname "$0")" || exit 2
want="TCG: Opal 2; locking supported, disabled, unlocked"
fake=$(mktemp -d); trap 'rm -rf "$fake"' EXIT
fail=0
for prefix in "" "NVME Security Receive Command Success"; do
  { [[ -n $prefix ]] && echo "$prefix"; cat fixtures/tcg-level0-intel760p.bin; } > "$fake/resp"
  printf '#!/bin/sh\ncat %s\n' "$fake/resp" > "$fake/nvme"; chmod +x "$fake/nvme"
  # shellcheck disable=SC1090
  got=$(PATH="$fake:$PATH"; source <(sed -n '/^tcg_level0() {/,/^}/p' ../src/wipestick); tcg_level0 /dev/nvme0 2>&1)
  if [[ $got == "$want" ]]; then echo "ok: ${prefix:-raw}"; else echo "FAIL (${prefix:-raw}): $got"; fail=1; fi
done
exit "$fail"
