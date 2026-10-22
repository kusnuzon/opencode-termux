#!/data/data/com.termux/files/usr/bin/bash
# install.sh — instalasi opencode (versi resmi terbaru) di Termux/Android, 1 perintah.
#
#   curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/install.sh | bash
#
# Opsi:
#   --check       hanya laporan status (terpasang vs terbaru), tidak mengubah apa pun
#   --upgrade     samakan dengan versi terbaru (default juga melakukan ini)
#   --version X   pasang versi tertentu, mis. --version 1.19.3
#   --dry-run     tampilkan rencana tanpa mengubah apa pun
#
# Kenapa perlu script ini: repo resmi anomalyco/opencode tidak punya build
# android/arm64 dan `npm i -g opencode-ai` gagal di Termux. Yang dipakai:
# binary glibc linux-arm64 dari GitHub release resmi, dijalankan lewat loader
# glibc milik Termux.
set -euo pipefail

REPO="kusnuzon/opencode-termux"
UPSTREAM="anomalyco/opencode"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
PAYLOAD_DIR="$PREFIX/share/opencode"
PAYLOAD="$PAYLOAD_DIR/opencode.real"
LAUNCHER="$PREFIX/bin/opencode"
BACKUP_DIR="$HOME/backups"
ASSET="opencode-linux-arm64.tar.gz"
MODE="install"
TARGET=""
KEEP_BACKUPS=2

c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'
c_b=$'\033[1;36m'; c_off=$'\033[0m'
step() { printf '\n%s=== %s ===%s\n' "$c_b" "$1" "$c_off"; }
say()  { printf '%s\n' "$*"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check)    MODE="check"; shift ;;
    --upgrade)  MODE="upgrade"; shift ;;
    --dry-run)  MODE="dry-run"; shift ;;
    --version)  TARGET="${2:-}"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "Argumen tidak dikenal: $1" ;;
  esac
done

# ---------- sanity: hanya Termux ----------
[ -d "$PREFIX" ] || die "Script ini hanya untuk Termux (Android)."
if [ "$(uname -o 2>/dev/null || echo unknown)" != "Android" ]; then
  die "Script ini hanya untuk Termux (Android). Di Linux biasa cukup: curl -fsSL https://opencode.ai/install | bash"
fi

api_get() {
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh api "$1" 2>/dev/null
  else
    curl -fsSL -H 'Accept: application/vnd.github+json' "$1"
  fi
}

latest_tag() {
  if [ -n "$TARGET" ]; then printf 'v%s' "${TARGET#v}"; return; fi
  api_get "https://api.github.com/repos/$UPSTREAM/releases/latest" |
    (command -v jq >/dev/null 2>&1 && jq -r '.tag_name' ||
     sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
}

installed_version() {
  if [ -x "$LAUNCHER" ]; then "$LAUNCHER" --version 2>/dev/null | tr -d '[:space:]' || true; fi
}

payload_version() {
  # cek payload langsung (dipakai kalau launcher belum ada)
  if [ -x "$PAYLOAD" ] && [ -x "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" ]; then
    "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" --library-path "$PREFIX/glibc/lib" "$PAYLOAD" --version 2>/dev/null |
      tr -d '[:space:]' || true
  fi
}

have_loader() { [ -x "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" ]; }

install_our_launcher() {
  local src=""
  if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/opencode-launcher" ]; then
    src="$SELF_DIR/opencode-launcher"
  else
    src="$(mktemp)"
    curl -fsSL -o "$src" "https://raw.githubusercontent.com/$REPO/main/opencode-launcher" ||
      die "Gagal mengunduh opencode-launcher dari repo."
  fi
  mkdir -p "$(dirname "$LAUNCHER")"
  sed "s|@PREFIX@|$PREFIX|g" "$src" > "$LAUNCHER"
  chmod 755 "$LAUNCHER"
  say "Launcher dipasang: $LAUNCHER"
}

prune_backups() {
  ls -1t "$BACKUP_DIR"/opencode-[0-9]*.tar.gz 2>/dev/null | tail -n "+$((KEEP_BACKUPS + 1))" |
    while read -r f; do rm -f "$f"; done
}

LATEST="$(latest_tag)"
[ -n "$LATEST" ] || die "Gagal mengambil versi terbaru dari GitHub API."
LATEST_NOV="${LATEST#v}"
CUR="$(installed_version)"
[ -n "$CUR" ] || CUR="$(payload_version)"

if [ "$MODE" = "check" ]; then
  say "Terpasang : ${CUR:-tidak ada}"
  say "Terbaru  : $LATEST_NOV"
  say "Launcher : $LAUNCHER"
  say "Payload  : $PAYLOAD"
  if [ "${CUR:-}" = "$LATEST_NOV" ]; then
    say "${c_ok}Sudah versi terbaru.${c_off}"
  else
    say "${c_warn}Ada versi baru — jalankan: bash install.sh --upgrade${c_off}"
  fi
  exit 0
fi

if [ "$MODE" = "dry-run" ]; then
  step "Rencana (dry-run, tidak ada yang diubah)"
  say "1. pkg install curl tar ca-certificates jq"
  say "2. pkg install glibc-repo glibc termux-exec-glibc"
  say "3. launcher: paket dpkg opencode (repo termuxvoid) atau opencode-launcher dari repo ini"
  say "4. unduh $ASSET untuk $LATEST_NOV"
  say "   mirror : https://github.com/$REPO/releases/download/opencode-termux-$LATEST_NOV/$ASSET"
  say "   upstream: https://github.com/$UPSTREAM/releases/download/$LATEST/$ASSET"
  say "5. pasang ke $PAYLOAD + verifikasi 'opencode --version'"
  say "Status sekarang: ${CUR:-tidak ada} | target: $LATEST_NOV"
  exit 0
fi

step "1/5 Paket dasar"
pkg update -y
pkg install -y curl tar ca-certificates jq

step "2/5 Runtime glibc (wajib: binary opencode = glibc, Android = bionic)"
pkg install -y glibc-repo || true
pkg update -y
pkg install -y glibc termux-exec-glibc
have_loader || die "Loader glibc tidak ditemukan: $PREFIX/glibc/lib/ld-linux-aarch64.so.1"

step "3/5 Launcher"
if dpkg -s opencode >/dev/null 2>&1 && [ -x "$LAUNCHER" ]; then
  say "Launcher dari paket dpkg (repo termuxvoid) dipakai."
  apt-mark hold opencode || true
  say "apt-mark hold opencode -> aman dari 'pkg upgrade' yang menimpa payload."
elif command -v pkg >/dev/null 2>&1; then
  TL="$PREFIX/etc/apt/sources.list.d/termuxvoid.list"
  [ -f "$TL" ] || printf 'deb [arch=all] https://termuxvoid.github.io/repo termuxvoid main\n' > "$TL"
  pkg update -y
  pkg install -y opencode || true
  if [ ! -x "$LAUNCHER" ]; then
    say "Paket termuxvoid tidak tersedia, memakai launcher bawaan repo ini."
    install_our_launcher
  fi
else
  install_our_launcher
fi

if [ "${CUR:-}" = "$LATEST_NOV" ] && [ -x "$PAYLOAD" ]; then
  step "4/5 Payload"
  say "${c_ok}opencode $CUR sudah versi terbaru ($LATEST_NOV). Tidak ada yang diubah.${c_off}"
else
  step "4/5 Unduh payload versi $LATEST_NOV"
  mkdir -p "$BACKUP_DIR" "$PAYLOAD_DIR"
  tmpdir="$(mktemp -d "$PREFIX/tmp/oc-install.XXXXXX")"
  trap 'rm -rf "$tmpdir"' EXIT
  MIRROR_URL="https://github.com/$REPO/releases/download/opencode-termux-$LATEST_NOV/$ASSET"
  UP_URL="https://github.com/$UPSTREAM/releases/download/$LATEST/$ASSET"
  if curl -fL --retry 2 --progress-bar -o "$tmpdir/pkg.tar.gz" "$MIRROR_URL"; then
    say "Sumber: mirror repo $REPO"
  else
    say "Mirror tidak tersedia, ambil dari upstream..."
    curl -fL --retry 3 --progress-bar -o "$tmpdir/pkg.tar.gz" "$UP_URL" || die "Gagal mengunduh $UP_URL"
  fi
  tar -xzf "$tmpdir/pkg.tar.gz" -C "$tmpdir" || die "Arsip rusak."
  # nama file di dalam arsip bisa "opencode" (rilisan upstream) atau
  # "opencode.real" (hasil backup/repack repo ini)
  if   [ -f "$tmpdir/opencode" ];      then BIN="$tmpdir/opencode"
  elif [ -f "$tmpdir/opencode.real" ]; then BIN="$tmpdir/opencode.real"
  else die "Isi arsip tidak sesuai (opencode tidak ditemukan di dalam arsip)."; fi
  chmod 755 "$BIN"

  ts="$(date +%Y%m%d-%H%M%S)"
  if [ -f "$PAYLOAD" ]; then
    say "Backup versi lama (${CUR:-lama}) -> $BACKUP_DIR/opencode-${CUR:-old}-$ts.tar.gz"
    tar -czf "$BACKUP_DIR/opencode-${CUR:-old}-$ts.tar.gz" -C "$PAYLOAD_DIR" opencode.real
    cp -f "$PAYLOAD" "$tmpdir/opencode.real.bak"
  fi
  cp -f "$BIN" "$PAYLOAD.new" && chmod 755 "$PAYLOAD.new" && mv -f "$PAYLOAD.new" "$PAYLOAD"
  [ -x "$LAUNCHER" ] || install_our_launcher
  prune_backups
fi

step "5/5 Verifikasi"
GOT="$(installed_version)"; [ -n "$GOT" ] || GOT="$(payload_version)"
if [ "$GOT" != "$LATEST_NOV" ]; then
  if [ -f "$tmpdir/opencode.real.bak" ]; then
    cp -f "$tmpdir/opencode.real.bak" "$PAYLOAD" && chmod 755 "$PAYLOAD"
    say "${c_warn}Payload lama dipulihkan (rollback).${c_off}"
  fi
  die "Verifikasi gagal (dapat: ${GOT:-kosong}, harusnya: $LATEST_NOV)."
fi
say "${c_ok}opencode $GOT siap dipakai.${c_off}"
say ""
say "Coba sekarang:   opencode"
say "Cek versi:       opencode --version"
say "Upgrade lagi:    bash install.sh --upgrade"
say "Hapus:           bash uninstall.sh"
