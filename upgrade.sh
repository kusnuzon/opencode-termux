#!/data/data/com.termux/files/usr/bin/bash
# upgrade.sh — upgrade opencode Termux ke versi resmi terbaru.
#
#   bash upgrade.sh            # upgrade ke terbaru (kalau sudah paling baru: no-op)
#   bash upgrade.sh --check    # hanya cek status
#   bash upgrade.sh 1.19.3     # pasang versi tertentu
#
# Setara dengan: bash install.sh --upgrade
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
exec bash "$DIR/install.sh" --upgrade "$@"
