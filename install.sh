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
#   --no-plugin   jangan pasang plugin bawaan (memory_save + judul sesi)
#   --no-extra    jangan pasang paket opsional besar (tesseract, chromium)
#   --no-memory   jangan pasang template memori/AGENTS/RECENT + hook ~/.bashrc
#   --with-memory (default) pasang memori pribadi + ringkasan sesi otomatis
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
NO_PLUGIN=0
NO_EXTRA=0
WITH_MEMORY=1

c_ok=$'\033[1;32m'; c_warn=$'\033[1;33m'; c_err=$'\033[1;31m'
c_b=$'\033[1;36m'; c_off=$'\033[0m'
step() { printf '\n%s=== %s ===%s\n' "$c_b" "$1" "$c_off"; }
say()  { printf '%s\n' "$*"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check)    MODE="check"; shift ;;
    --upgrade)  MODE="upgrade"; shift ;;
    --dry-run)  MODE="dry-run"; shift ;;
    --version)  TARGET="${2:-}"; shift 2 ;;
    --no-plugin) NO_PLUGIN=1; shift ;;
    --no-extra) NO_EXTRA=1; shift ;;
    --no-memory) WITH_MEMORY=0; shift ;;
    --with-memory) WITH_MEMORY=1; shift ;;
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

# download_url <url> <dest> [accept] — curl → wget → python.
# Latar: paket glibc di Termux bisa membuat curl mati dengan
# "cannot locate symbol SSL_set_quic_tls_early_data_enabled"; tanpa cadangan
# ini seluruh unduhan berikutnya ikut gagal.
download_url() {
  local url="$1" dest="$2" accept="${3:-}" part="$2.part"
  mkdir -p "$(dirname "$dest")" || return 1
  rm -f "$part"
  if [ -n "$accept" ]; then
    curl -fsSL --max-time 300 -H "Accept: $accept" "$url" -o "$part" 2>/dev/null
  else
    curl -fsSL --max-time 300 "$url" -o "$part" 2>/dev/null
  fi
  if [ -s "$part" ]; then mv -f "$part" "$dest"; return 0; fi
  rm -f "$part"
  if command -v wget >/dev/null 2>&1 && wget -q --timeout=60 -O "$part" "$url" >/dev/null 2>&1 && [ -s "$part" ]; then
    mv -f "$part" "$dest"; return 0
  fi
  rm -f "$part"
  if command -v python >/dev/null 2>&1; then
    python - "$url" "$part" "$accept" <<'PY' >/dev/null 2>&1 || true
import sys, urllib.request
url, dest, accept = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")
req = urllib.request.Request(url, headers={"User-Agent": "opencode-termux"})
if accept:
    req.add_header("Accept", accept)
open(dest, "wb").write(urllib.request.urlopen(req, timeout=60).read())
PY
    [ -s "$part" ] && { mv -f "$part" "$dest"; return 0; }
  fi
  rm -f "$part"
  return 1
}

# fetch_file <path-di-repo> <tujuan> — pakai API (selalu segar), fallback raw.
fetch_file() {
  local path="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  download_url "https://api.github.com/repos/$REPO/contents/$path?ref=main" "$dest" \
    'application/vnd.github.raw' && return 0
  download_url "https://raw.githubusercontent.com/$REPO/main/$path" "$dest"
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
    download_url "https://raw.githubusercontent.com/$REPO/main/opencode-launcher" "$src" ||
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

# ---------- dependensi dasar (sebelum menyentuh GitHub) ---------------------
# Termux baru: paket dasar ini harus ada lebih dulu, dan curl bisa rusak oleh
# paket glibc ("cannot locate symbol SSL_set_quic_tls_early_data_enabled").
BASE_PKGS="curl tar unzip gzip coreutils ca-certificates jq python git sqlite wget openssh gh nodejs yq shellcheck ncdu htop"
# Opsional/besar: butuh repo x11-repo; gagal = peringatan saja, bukan error.
EXTRA_PKGS="tesseract chromium"

apt_update() {
  local i
  for i in 1 2 3; do
    pkg update -y >/dev/null 2>&1 && return 0
    sleep $((i * 2))
  done
  return 1
}

curl_ok() { curl -fsS --max-time 10 -o /dev/null https://github.com >/dev/null 2>&1; }

heal_curl() {
  curl_ok && return 0
  say "curl tidak sehat — memasang ulang curl/libcurl/openssl"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
    -o Dpkg::Options::=--force-confold curl libcurl openssl ca-certificates >/dev/null 2>&1 || \
    pkg install -y curl libcurl openssl ca-certificates >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  curl_ok
}

ensure_base_deps() {
  apt_update || say "! peringatan: 'pkg update' gagal (lanjut, pakai daftar paket lama)"
  # shellcheck disable=SC2086
  pkg install -y $BASE_PKGS || die "gagal memasang paket dasar: $BASE_PKGS"
  heal_curl || say "! curl masih bermasalah; unduhan akan mencoba wget"
  # Opsional: jangan gagalkan install kalau repo/paketnya tidak tersedia.
  if [ "$NO_EXTRA" -eq 0 ]; then
    pkg install -y x11-repo >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    pkg install -y $EXTRA_PKGS >/dev/null 2>&1 ||
      say "! paket opsional dilewati: $EXTRA_PKGS (bisa dipasang nanti: pkg install $EXTRA_PKGS)"
  fi
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
  say "1. pkg install $BASE_PKGS (dijalankan otomatis + curl dipulihkan bila rusak)"
  say "2. pkg install glibc-repo glibc termux-exec-glibc"
  say "3. launcher: paket dpkg opencode (repo termuxvoid) atau opencode-launcher dari repo ini"
  say "4. unduh $ASSET untuk $LATEST_NOV"
  say "   mirror : https://github.com/$REPO/releases/download/opencode-termux-$LATEST_NOV/$ASSET"
  say "   upstream: https://github.com/$UPSTREAM/releases/download/$LATEST/$ASSET"
  say "5. pasang ke $PAYLOAD + verifikasi 'opencode --version'"
  [ "$NO_PLUGIN" -eq 0 ] && say "6. pasang plugin bawaan (memory_save + judul sesi)"
  [ "$WITH_MEMORY" -eq 1 ] && say "   pasang MEMORY.md/AGENTS.md/RECENT.md + hook ~/.bashrc"
  say "Status sekarang: ${CUR:-tidak ada} | target: $LATEST_NOV"
  exit 0
fi

step "1/6 Paket dasar + dependensi"
# Dependensi yang dipakai fitur bawaan (plugin, digest sesi, sync memori).
# Dipasang di awal supaya Termux baru tidak error di tengah jalan.
ensure_base_deps

step "2/6 Runtime glibc (wajib: binary opencode = glibc, Android = bionic)"
pkg install -y glibc-repo >/dev/null 2>&1 || true
apt_update || true
pkg install -y glibc termux-exec-glibc || die "gagal memasang glibc/termux-exec-glibc"
have_loader || die "Loader glibc tidak ditemukan: $PREFIX/glibc/lib/ld-linux-aarch64.so.1"
# Urutan penting: glibc dulu, baru curl diperiksa lagi.
heal_curl || say "! curl tetap bermasalah setelah glibc"

step "3/6 Launcher"
if dpkg -s opencode >/dev/null 2>&1 && [ -x "$LAUNCHER" ]; then
  say "Launcher dari paket dpkg (repo termuxvoid) dipakai."
  apt-mark hold opencode || true
  say "apt-mark hold opencode -> aman dari 'pkg upgrade' yang menimpa payload."
elif command -v pkg >/dev/null 2>&1; then
  TL="$PREFIX/etc/apt/sources.list.d/termuxvoid.list"
  # [trusted=yes] wajib: repo termuxvoid tidak menandatangani InRelease, dan
  # tanpa ini `pkg update` gagal: "NO_PUBKEY … repository is not signed".
  # File lama (dibuat versi sebelumnya tanpa trusted=yes) ikut diperbaiki.
  if [ -f "$TL" ]; then
    if ! grep -q 'trusted=yes' "$TL"; then
      cp "$TL" "$TL.bak-$(date +%Y%m%d-%H%M%S)"
      printf 'deb [arch=all trusted=yes] https://termuxvoid.github.io/repo termuxvoid main\n' > "$TL"
      say "sources.list termuxvoid diperbaiki (tambah trusted=yes)"
    fi
  else
    printf 'deb [arch=all trusted=yes] https://termuxvoid.github.io/repo termuxvoid main\n' > "$TL"
  fi
  apt_update || say "! peringatan: 'pkg update' gagal setelah menambah repo termuxvoid"
  pkg install -y opencode || true
  if [ ! -x "$LAUNCHER" ]; then
    say "Paket termuxvoid tidak tersedia, memakai launcher bawaan repo ini."
    install_our_launcher
  fi
else
  install_our_launcher
fi

if [ "${CUR:-}" = "$LATEST_NOV" ] && [ -x "$PAYLOAD" ]; then
  step "4/6 Payload"
  say "${c_ok}opencode $CUR sudah versi terbaru ($LATEST_NOV). Tidak ada yang diubah.${c_off}"
else
  step "4/6 Unduh payload versi $LATEST_NOV"
  mkdir -p "$BACKUP_DIR" "$PAYLOAD_DIR"
  tmpdir="$(mktemp -d "$PREFIX/tmp/oc-install.XXXXXX")"
  trap 'rm -rf "$tmpdir"' EXIT
  MIRROR_URL="https://github.com/$REPO/releases/download/opencode-termux-$LATEST_NOV/$ASSET"
  UP_URL="https://github.com/$UPSTREAM/releases/download/$LATEST/$ASSET"
  if download_url "$MIRROR_URL" "$tmpdir/pkg.tar.gz"; then
    say "Sumber: mirror repo $REPO"
  else
    say "Mirror tidak tersedia, ambil dari upstream..."
    download_url "$UP_URL" "$tmpdir/pkg.tar.gz" || die "Gagal mengunduh $UP_URL"
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

step "5/6 Verifikasi"
GOT="$(installed_version)"; [ -n "$GOT" ] || GOT="$(payload_version)"
if [ "$GOT" != "$LATEST_NOV" ]; then
  if [ -f "$tmpdir/opencode.real.bak" ]; then
    cp -f "$tmpdir/opencode.real.bak" "$PAYLOAD" && chmod 755 "$PAYLOAD"
    say "${c_warn}Payload lama dipulihkan (rollback).${c_off}"
  fi
  die "Verifikasi gagal (dapat: ${GOT:-kosong}, harusnya: $LATEST_NOV)."
fi

step "6/6 Plugin & ingatan lintas sesi"
OC_DIR="$HOME/.config/opencode"
PLUGIN_DIR="$OC_DIR/plugins"
STAGE="$SELF_DIR"
[ -n "$STAGE" ] || STAGE="$(mktemp -d "$PREFIX/tmp/oc-mem.XXXXXX")"

install_plugin() {
  local name="$1" src="$STAGE/plugins/$1" dst="$PLUGIN_DIR/$1" backup
  if [ ! -s "$src" ]; then
    fetch_file "plugins/$name" "$src" || { say "${c_warn}gagal mengunduh plugins/$name${c_off}"; return 1; }
  fi
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    if [ "$name" = "memory.js" ]; then
      backup="$dst.v1.bak"
      [ -e "$backup" ] && backup="$dst.v1.$(date +%Y%m%d%H%M%S).bak"
    else
      backup="$dst.bak-$(date +%Y%m%d%H%M%S)"
    fi
    cp "$dst" "$backup"
    say "Plugin lama dicadangkan ke $backup"
  fi
  cp "$src" "$dst"
  chmod 600 "$dst" 2>/dev/null || true
  say "Plugin terpasang: $dst"
}

if [ "$NO_PLUGIN" -eq 1 ]; then
  say "Plugin bawaan dilewati (--no-plugin)"
else
  mkdir -p "$PLUGIN_DIR"
  install_plugin memory.js || true
  install_plugin session-title.js || true
fi

if [ "$WITH_MEMORY" -eq 1 ]; then
  mkdir -p "$OC_DIR/bin"
  DIGEST="$OC_DIR/bin/session-digest.py"
  DIGEST_SRC="$STAGE/plugins/session-digest.py"
  if [ ! -s "$DIGEST_SRC" ]; then
    fetch_file "plugins/session-digest.py" "$DIGEST_SRC" || say "${c_warn}gagal mengunduh session-digest.py${c_off}"
  fi
  if [ -s "$DIGEST_SRC" ]; then
    cp "$DIGEST_SRC" "$DIGEST"
    sed -i "1s|^#!.*|#!$PREFIX/bin/python3|" "$DIGEST"
    chmod 755 "$DIGEST"
    say "Generator ringkasan sesi: $DIGEST"
  fi

  # Template hanya dipasang kalau belum ada — memori user tidak boleh tertimpa.
  for f in MEMORY.md AGENTS.md opencode.jsonc; do
    if [ -f "$OC_DIR/$f" ]; then
      say "sudah ada, dilewati: $OC_DIR/$f"
      continue
    fi
    src="$STAGE/memory/$f"
    if [ ! -s "$src" ]; then
      fetch_file "memory/$f" "$src" || { say "${c_warn}gagal mengambil memory/$f${c_off}"; continue; }
    fi
    cp "$src" "$OC_DIR/$f"
    if [ "$f" = "opencode.jsonc" ]; then
      sed -i "s|/data/data/com.termux/files/home|$HOME|g" "$OC_DIR/$f"
    fi
  done
  [ -f "$OC_DIR/RECENT.md" ] || printf '# RECENT\n\nBelum ada sesi tercatat.\n' >"$OC_DIR/RECENT.md"
  if [ -x "$DIGEST" ]; then
    python3 "$DIGEST" >/dev/null 2>&1 || true
  fi
  say "Memori/template, aturan, dan instructions siap di $OC_DIR"

  if ! grep -q "_oc_refresh_digest" "$HOME/.bashrc" 2>/dev/null; then
    [ -f "$HOME/.bashrc" ] || : >"$HOME/.bashrc"
    cat >>"$HOME/.bashrc" <<'EOS'

# --- segarkan ringkasan sesi sebelum opencode dibuka (install.sh) ---
_oc_refresh_digest() {
  [ -x "$HOME/.config/opencode/bin/session-digest.py" ] || return 0
  python3 "$HOME/.config/opencode/bin/session-digest.py" >/dev/null 2>&1
}
opencode() { _oc_refresh_digest; command opencode "$@"; }
opencode-v2() { _oc_refresh_digest; command opencode-v2 "$@"; }
EOS
    say "~/.bashrc: ringkasan sesi disegarkan otomatis"
  fi
fi
[ -n "$SELF_DIR" ] || rm -rf "$STAGE"

say "${c_ok}opencode $GOT siap dipakai.${c_off}"
say ""
say "Coba sekarang:   opencode"
say "Cek versi:       opencode --version"
say "Upgrade lagi:    bash install.sh --upgrade"
say "Hapus:           bash uninstall.sh"
