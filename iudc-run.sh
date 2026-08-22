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

# Run a command in its own process group (setsid) so a cancelled transaction
# tears down the whole tree (yay -> makepkg / sudo pacman), not just the
# top-level process. The panel sends SIGTERM to the runner; the trap forwards
# it to the group.
_child=""
teardown() {
  [[ -n $_child ]] || exit 143
  kill -TERM -- -"$_child" 2>/dev/null
  kill -TERM "$_child" 2>/dev/null
}
trap teardown TERM INT

run() {
  setsid "$@" &
  _child=$!
  wait "$_child"
  local rc=$?
  _child=""
  exit $rc
}

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
    run pkexec pacman -Sy --color=never
    ;;
  upgrade)
    echo ">>> Upgrading system (official repositories)…"
    run pkexec pacman -Syu --color=never --noconfirm || exit $?
    if [[ ${2:-} == aur ]]; then
      echo ""
      echo ">>> Upgrading AUR packages…"
      use_askpass_sudo
      run yay -Sua --color=never --noconfirm
    fi
    exit 0
    ;;
  install-repo)
    [[ -n $arg ]] || fail "missing package name"
    echo ">>> Installing repository package: $arg"
    run pkexec pacman -S --color=never --noconfirm --needed "$arg"
    ;;
  install-aur)
    [[ -n $arg ]] || fail "missing package name"
    echo ">>> Installing AUR package: $arg"
    use_askpass_sudo
    run yay -S --color=never --noconfirm --needed "$arg"
    ;;
  remove)
    [[ -n $arg ]] || fail "missing package name"
    echo ">>> Removing package: $arg"
    run pkexec pacman -Rns --color=never --noconfirm "$arg"
    ;;
  clean-paccache)
    keep="${arg:-2}"
    [[ $keep =~ ^[0-9]+$ ]] || keep=2
    echo ">>> Pruning pacman cache (keeping $keep version(s))…"
    run pkexec paccache -rk "$keep"
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
