#!/usr/bin/env bash
# arch.iudc — list every package available in the official repositories.
# Emits pacman -Sl lines: "<repo> <name> <version> [installed]"; the QML side
# parses and sorts them. Read-only.
set -uo pipefail
export LC_ALL=C

pacman -Sl --color=never
exit 0
