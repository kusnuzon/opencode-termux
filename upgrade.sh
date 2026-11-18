#!/data/data/com.termux/files/usr/bin/bash
# upgrade.sh — upgrade opencode Termux to the latest official version.
#
#   bash upgrade.sh            # upgrade to the latest (no-op if already current)
#   bash upgrade.sh --check    # status check only
#   bash upgrade.sh 1.19.3     # install a specific version
#
# Equivalent to: bash install.sh --upgrade
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# A bare version ("upgrade.sh 1.19.3", as the usage above promises) must map to
# --version; flags pass through untouched. install.sh rejects unknown arguments,
# so a bare version used to die there.
case "${1:-}" in
  "" | -*) exec bash "$DIR/install.sh" --upgrade "$@" ;;
  *) exec bash "$DIR/install.sh" --upgrade --version "$@" ;;
esac
