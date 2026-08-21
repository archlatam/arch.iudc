#!/usr/bin/env bash
# arch.iudc — pending update check.
# Emits tab-separated lines:  SOURCE<TAB>name<TAB>oldver<TAB>newver
# SOURCE is "repo" for official repositories, "aur" for foreign packages.
# $1 = "all" | "repo" | "aur"
set -uo pipefail
export LC_ALL=C

mode="${1:-all}"

if [[ $mode != aur ]]; then
  checkupdates 2>/dev/null |
    awk -F' -> ' '{ n=split($1,a," "); if (n>=2) print "repo\t"a[1]"\t"a[2]"\t"$2 }'
fi

if [[ $mode != repo ]] && command -v yay >/dev/null 2>&1; then
  yay -Qua --color=never 2>/dev/null |
    awk -F' -> ' '{ n=split($1,a," "); if (n>=2) print "aur\t"a[1]"\t"a[2]"\t"$2 }'
fi

exit 0
