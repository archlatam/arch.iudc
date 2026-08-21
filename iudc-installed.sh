#!/usr/bin/env bash
# arch.iudc — installed package inventory.
# Emits: native section (pacman -Qn), marker, foreign/AUR section (pacman -Qm),
# then a summary line with cache sizes for the Cache tab.
set -uo pipefail
export LC_ALL=C

echo "---IUDC-NATIVE---"
pacman -Qn 2>/dev/null

echo "---IUDC-FOREIGN---"
pacman -Qm 2>/dev/null

echo "---IUDC-CACHE---"
if command -v paccache >/dev/null 2>&1; then
  paccache -d 2>/dev/null | tail -n 2
fi
du -sh "$HOME/.cache/yay" 2>/dev/null | tail -n 1

exit 0
