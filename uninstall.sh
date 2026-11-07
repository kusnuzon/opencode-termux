#!/data/data/com.termux/files/usr/bin/bash
# uninstall.sh — remove opencode (payload + launcher) from Termux.
#
#   bash uninstall.sh            # remove payload + launcher
#   bash uninstall.sh --purge    # also drop the opencode dpkg package + glibc runtime
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PAYLOAD="$PREFIX/share/opencode/opencode.real"
LAUNCHER="$PREFIX/bin/opencode"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if [ -f "$PAYLOAD" ]; then
  rm -f "$PAYLOAD"
  printf 'Removed: %s\n' "$PAYLOAD"
fi
if [ -f "$LAUNCHER" ] && ! dpkg -s opencode >/dev/null 2>&1; then
  rm -f "$LAUNCHER"
  printf 'Removed: %s\n' "$LAUNCHER"
fi
if [ "$PURGE" = "1" ]; then
  apt-mark unhold opencode 2>/dev/null || true
  pkg uninstall -y opencode || true
  pkg uninstall -y termux-exec-glibc glibc glibc-repo || true
  printf 'glibc + opencode packages removed.\n'
fi
printf 'Done. opencode config/sessions (~/.config/opencode, ~/.local/share/opencode) were NOT removed.\n'
