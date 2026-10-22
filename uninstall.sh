#!/data/data/com.termux/files/usr/bin/bash
# uninstall.sh — hapus opencode (payload + launcher) dari Termux.
#
#   bash uninstall.sh            # hapus payload + launcher
#   bash uninstall.sh --purge    # sekaligus lepas paket dpkg opencode + runtime glibc
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PAYLOAD="$PREFIX/share/opencode/opencode.real"
LAUNCHER="$PREFIX/bin/opencode"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if [ -f "$PAYLOAD" ]; then
  rm -f "$PAYLOAD"
  printf 'Dihapus: %s\n' "$PAYLOAD"
fi
if [ -f "$LAUNCHER" ] && ! dpkg -s opencode >/dev/null 2>&1; then
  rm -f "$LAUNCHER"
  printf 'Dihapus: %s\n' "$LAUNCHER"
fi
if [ "$PURGE" = "1" ]; then
  apt-mark unhold opencode 2>/dev/null || true
  pkg uninstall -y opencode || true
  pkg uninstall -y termux-exec-glibc glibc glibc-repo || true
  printf 'Paket glibc + opencode dilepas.\n'
fi
printf 'Selesai. Config/sesi opencode (~/.config/opencode, ~/.local/share/opencode) TIDAK dihapus.\n'
