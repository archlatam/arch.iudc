#!/usr/bin/env bash
# arch.iudc — package search across official repos and the AUR.
# $1 = query (sanitized by caller). Emits sections separated by markers so the
# QML side can tell repo results from AUR results.
set -uo pipefail
export LC_ALL=C

q="${1:-}"
[[ -n $q ]] || exit 0

echo "---IUDC-REPO---"
pacman -Ss --color=never "$q" 2>/dev/null

echo "---IUDC-AUR---"
if command -v yay >/dev/null 2>&1; then
  yay -Ssa --color=never "$q" 2>/dev/null
fi

exit 0
