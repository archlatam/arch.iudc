#!/usr/bin/env bash
# arch.iudc — graphical SUDO_ASKPASS helper used by yay's internal sudo calls.
cmd="${IUDC_SUDO_CMD:-pacman}"
zenity --password --title="Pacman - sudo password" \
  --text="Authorizing: sudo ${cmd}" 2>/dev/null
