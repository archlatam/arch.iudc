#!/usr/bin/env bash
# arch.iudc — package details for the info view.
# $1 = package name, $2 = "installed" | "remote"
# Emits pacman -Qi/-Si key/value output (AUR packages get yay -Si).
set -uo pipefail
export LC_ALL=C

pkg="${1:-}"
state="${2:-remote}"
[[ -n $pkg ]] || exit 0

echo "---IUDC-INFO---"
if [[ $state == installed ]]; then
  pacman -Qi --color=never "$pkg" 2>/dev/null
else
  if ! pacman -Si --color=never "$pkg" 2>/dev/null; then
    command -v yay >/dev/null 2>&1 && yay -Si --color=never "$pkg" 2>/dev/null
  fi
fi

exit 0
