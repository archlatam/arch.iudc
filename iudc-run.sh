#!/usr/bin/env bash
# arch.iudc — transaction runner. All output goes to stdout/stderr and is
# streamed into the panel console by the QML Process.
#
# Usage: iudc-run.sh <mode> [args]
#   sync                    refresh databases            (pkexec pacman -Sy)
#   upgrade [aur]           full system upgrade          (pkexec pacman -Syu)
#                           + AUR remainder when "aur"   (yay -Sua, sudo via askpass)
#   install-repo <pkg>      install from official repos  (pkexec pacman -S)
#   install-aur <pkg>       install/build from AUR       (yay -S, sudo via askpass)
#   remove <pkg>            uninstall package            (pkexec pacman -Rns)
#   clean-paccache <keep>   prune pacman cache versions  (pkexec paccache -rk)
#   clean-aurcache          wipe yay/AUR build cache     (user-level rm)
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-}"
arg="${2:-}"

fail() { echo "iudc: $*" >&2; exit 1; }

# Route yay's internal `sudo` calls through `sudo -A` so the password prompt is
# answered by the graphical askpass helper instead of requiring a terminal.
use_askpass_sudo() {
  export SUDO_ASKPASS="$DIR/askpass.sh"
  [[ -x $SUDO_ASKPASS ]] || fail "askpass.sh missing or not executable"
  export PATH="$DIR/sudo-shim:$PATH"
}

case "$mode" in
  sync)
    echo ">>> Syncing package databases…"
    exec pkexec pacman -Sy --color=never
    ;;
  upgrade)
    echo ">>> Upgrading system (official repositories)…"
    pkexec pacman -Syu --color=never --noconfirm || exit $?
    if [[ ${2:-} == aur ]]; then
      echo ""
      echo ">>> Upgrading AUR packages…"
      use_askpass_sudo
      exec yay -Sua --color=never --noconfirm
    fi
    exit 0
    ;;
  install-repo)
    [[ -n $arg ]] || fail "missing package name"
    echo ">>> Installing repository package: $arg"
    exec pkexec pacman -S --color=never --noconfirm --needed "$arg"
    ;;
  install-aur)
    [[ -n $arg ]] || fail "missing package name"
    echo ">>> Installing AUR package: $arg"
    use_askpass_sudo
    exec yay -S --color=never --noconfirm --needed "$arg"
    ;;
  remove)
    [[ -n $arg ]] || fail "missing package name"
    echo ">>> Removing package: $arg"
    exec pkexec pacman -Rns --color=never --noconfirm "$arg"
    ;;
  clean-paccache)
    keep="${arg:-2}"
    [[ $keep =~ ^[0-9]+$ ]] || keep=2
    echo ">>> Pruning pacman cache (keeping $keep version(s))…"
    exec pkexec paccache -rk "$keep"
    ;;
  clean-aurcache)
    echo ">>> Clearing AUR build cache (~/.cache/yay)…"
    find "$HOME/.cache/yay" -mindepth 1 -delete 2>/dev/null
    echo "Done."
    exit 0
    ;;
  *)
    fail "unknown mode: $mode"
    ;;
esac
