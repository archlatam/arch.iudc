#!/usr/bin/env bash
# arch.iudc — package search across official repos and the AUR.
# $1 = query (sanitized by caller). Emits sections separated by markers so the
# QML side can tell repo results from AUR results. Both searches run in
# parallel; total latency is the slower of the two, not their sum.
set -uo pipefail
export LC_ALL=C

q="${1:-}"
[[ -n $q ]] || exit 0

tmp_repo=$(mktemp)
tmp_aur=$(mktemp)
trap 'rm -f "$tmp_repo" "$tmp_aur"' EXIT

pacman -Ss --color=never -- "$q" >"$tmp_repo" 2>/dev/null &
pid_repo=$!

pid_aur=""
if command -v yay >/dev/null 2>&1; then
  yay -Ssa --color=never -- "$q" >"$tmp_aur" 2>/dev/null &
  pid_aur=$!
fi

wait "$pid_repo" 2>/dev/null
echo "---IUDC-REPO---"
cat "$tmp_repo"

if [[ -n $pid_aur ]]; then
  wait "$pid_aur" 2>/dev/null
fi
echo "---IUDC-AUR---"
cat "$tmp_aur"

exit 0
