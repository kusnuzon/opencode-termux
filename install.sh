#!/data/data/com.termux/files/usr/bin/bash
# install.sh — install opencode (latest official build) on Termux/Android in one command.
#
#   curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/install.sh | bash
#
# Options:
#   --check       status report only (installed vs latest), changes nothing
#   --upgrade     match the latest version (the default does this too)
#   --version X   install a specific version, e.g. --version 1.19.3
#   --dry-run     print the plan without changing anything
#   --no-plugin   skip the bundled plugins (memory_save + session titles)
#   --no-extra    skip the large optional packages (tesseract, chromium)
#   --no-memory   skip the memory/AGENTS/RECENT templates + ~/.bashrc hook
#   --with-memory (default) install personal memory + automatic session summaries
#
# Why this script exists: the official anomalyco/opencode repo has no
# android/arm64 build and `npm i -g opencode-ai` fails on Termux. Instead we use
# the glibc linux-arm64 binary from the official GitHub release, run through the
# glibc loader that ships with Termux.
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
    *) die "Unknown argument: $1" ;;
  esac
done

# ---------- sanity: Termux only ----------
[ -d "$PREFIX" ] || die "This script is for Termux (Android) only."
if [ "$(uname -o 2>/dev/null || echo unknown)" != "Android" ]; then
  die "This script is for Termux (Android) only. On regular Linux just run: curl -fsSL https://opencode.ai/install | bash"
fi

api_get() {
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh api "$1" 2>/dev/null
  else
    curl -fsSL -H 'Accept: application/vnd.github+json' "$1"
  fi
}

# download_url <url> <dest> [accept] — curl → wget → python.
# Background: the glibc packages on Termux can break curl with
# "cannot locate symbol SSL_set_quic_tls_early_data_enabled"; without this
# fallback every later download would fail too.
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

# fetch_file <repo-path> <destination> — use the API (always fresh), fall back to raw.
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
  # read the payload directly (used when the launcher is not there yet)
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
      die "Failed to download opencode-launcher from the repo."
  fi
  mkdir -p "$(dirname "$LAUNCHER")"
  sed "s|@PREFIX@|$PREFIX|g" "$src" > "$LAUNCHER"
  chmod 755 "$LAUNCHER"
  say "Launcher installed: $LAUNCHER"
}

prune_backups() {
  ls -1t "$BACKUP_DIR"/opencode-[0-9]*.tar.gz 2>/dev/null | tail -n "+$((KEEP_BACKUPS + 1))" |
    while read -r f; do rm -f "$f"; done
}

# ---------- base dependencies (before touching GitHub) ----------------------
# Fresh Termux: these base packages must exist first, and curl can be broken by
# the glibc packages ("cannot locate symbol SSL_set_quic_tls_early_data_enabled").
BASE_PKGS="curl tar unzip gzip coreutils ca-certificates jq python git sqlite wget openssh gh ncdu htop"
# Optional/large: needs the x11-repo; a failure is only a warning, not an error.
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
  say "curl is unhealthy — reinstalling curl/libcurl/openssl"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
    -o Dpkg::Options::=--force-confold curl libcurl openssl ca-certificates >/dev/null 2>&1 || \
    pkg install -y curl libcurl openssl ca-certificates >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  curl_ok
}

ensure_base_deps() {
  apt_update || say "! warning: 'pkg update' failed (continuing with the cached package lists)"
  # shellcheck disable=SC2086
  pkg install -y $BASE_PKGS || die "failed to install base packages: $BASE_PKGS"
  heal_curl || say "! curl is still broken; downloads will fall back to wget"
  # Optional: never fail the install when the repo/package is unavailable.
  if [ "$NO_EXTRA" -eq 0 ]; then
    pkg install -y x11-repo >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    pkg install -y $EXTRA_PKGS >/dev/null 2>&1 ||
      say "! optional packages skipped: $EXTRA_PKGS (install later with: pkg install $EXTRA_PKGS)"
  fi
}

LATEST="$(latest_tag)"
[ -n "$LATEST" ] || die "Failed to fetch the latest version from the GitHub API."
LATEST_NOV="${LATEST#v}"
CUR="$(installed_version)"
[ -n "$CUR" ] || CUR="$(payload_version)"

if [ "$MODE" = "check" ]; then
  say "Installed : ${CUR:-none}"
  say "Latest    : $LATEST_NOV"
  say "Launcher  : $LAUNCHER"
  say "Payload   : $PAYLOAD"
  if [ "${CUR:-}" = "$LATEST_NOV" ]; then
    say "${c_ok}Already on the latest version.${c_off}"
  else
    say "${c_warn}A newer version is available — run: bash install.sh --upgrade${c_off}"
  fi
  exit 0
fi

if [ "$MODE" = "dry-run" ]; then
  step "Plan (dry-run, nothing will be changed)"
  say "1. pkg install $BASE_PKGS (run automatically, curl healed if broken)"
  say "2. pkg install glibc-repo glibc termux-exec-glibc"
  say "3. launcher: opencode-launcher from this repo (small script, no clang/LLVM)"
  say "4. download $ASSET for $LATEST_NOV"
  say "   mirror  : https://github.com/$REPO/releases/download/opencode-termux-$LATEST_NOV/$ASSET"
  say "   upstream: https://github.com/$UPSTREAM/releases/download/$LATEST/$ASSET"
  say "5. install into $PAYLOAD + verify with 'opencode --version'"
  [ "$NO_PLUGIN" -eq 0 ] && say "6. install the bundled plugins (memory_save + session titles)"
  [ "$WITH_MEMORY" -eq 1 ] && say "   install MEMORY.md/AGENTS.md/RECENT.md + ~/.bashrc hook"
  say "Current status: ${CUR:-none} | target: $LATEST_NOV"
  exit 0
fi

step "1/6 Base packages + dependencies"
# Dependencies used by the built-in features (plugins, session digest, memory sync).
# Installed up front so a fresh Termux does not fail halfway through.
ensure_base_deps

step "2/6 glibc runtime (required: the opencode binary is glibc, Android is bionic)"
pkg install -y glibc-repo >/dev/null 2>&1 || true
apt_update || true
pkg install -y glibc termux-exec-glibc || die "failed to install glibc/termux-exec-glibc"
have_loader || die "glibc loader not found: $PREFIX/glibc/lib/ld-linux-aarch64.so.1"
# Order matters: glibc first, then check curl again.
heal_curl || say "! curl is still broken after glibc"

step "3/6 Launcher"
# Use the small script launcher in this repo. The old termuxvoid `opencode`
# dpkg package also worked, but it depends on clang + LLVM (~500 MB) that the
# runtime never needs. Unless OPENCODE_USE_DPKG=1 is set, an existing dpkg
# install is migrated automatically.
if [ "${OPENCODE_USE_DPKG:-0}" = "1" ] && command -v pkg >/dev/null 2>&1; then
  TL="$PREFIX/etc/apt/sources.list.d/termuxvoid.list"
  if [ -f "$TL" ]; then
    if ! grep -q 'trusted=yes' "$TL"; then
      cp "$TL" "$TL.bak-$(date +%Y%m%d-%H%M%S)"
      printf 'deb [arch=all trusted=yes] https://termuxvoid.github.io/repo termuxvoid main\n' > "$TL"
      say "termuxvoid sources.list repaired (trusted=yes added)"
    fi
  else
    printf 'deb [arch=all trusted=yes] https://termuxvoid.github.io/repo termuxvoid main\n' > "$TL"
  fi
  apt_update || say "! warning: 'pkg update' failed after adding the termuxvoid repo"
  pkg install -y opencode || true
  if dpkg -s opencode >/dev/null 2>&1; then
    rm -f "$TL"
    apt-mark hold opencode || true
    apt_update || true
  fi
fi
if [ "${OPENCODE_USE_DPKG:-0}" = "1" ] && dpkg -s opencode >/dev/null 2>&1; then
  say "Using the launcher from the opencode dpkg package (OPENCODE_USE_DPKG=1)."
else
  if dpkg -s opencode >/dev/null 2>&1; then
    say "Migrating away from the opencode dpkg launcher (frees clang/LLVM, ~500 MB)."
    apt-mark unhold opencode 2>/dev/null || true
    pkg remove -y opencode >/dev/null 2>&1 || apt-get remove -y opencode >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
  fi
  install_our_launcher
fi

if [ "${CUR:-}" = "$LATEST_NOV" ] && [ -x "$PAYLOAD" ]; then
  step "4/6 Payload"
  say "${c_ok}opencode $CUR is already the latest version ($LATEST_NOV). Nothing changed.${c_off}"
else
  step "4/6 Downloading payload version $LATEST_NOV"
  mkdir -p "$BACKUP_DIR" "$PAYLOAD_DIR"
  tmpdir="$(mktemp -d "$PREFIX/tmp/oc-install.XXXXXX")"
  trap 'rm -rf "$tmpdir"' EXIT
  MIRROR_URL="https://github.com/$REPO/releases/download/opencode-termux-$LATEST_NOV/$ASSET"
  UP_URL="https://github.com/$UPSTREAM/releases/download/$LATEST/$ASSET"
  if download_url "$MIRROR_URL" "$tmpdir/pkg.tar.gz"; then
    say "Source: mirror in repo $REPO"
  else
    say "Mirror unavailable, fetching from upstream..."
    download_url "$UP_URL" "$tmpdir/pkg.tar.gz" || die "Failed to download $UP_URL"
  fi
  tar -xzf "$tmpdir/pkg.tar.gz" -C "$tmpdir" || die "Corrupt archive."
  # the file inside the archive may be "opencode" (upstream release) or
  # "opencode.real" (backup/repack produced by this repo)
  if   [ -f "$tmpdir/opencode" ];      then BIN="$tmpdir/opencode"
  elif [ -f "$tmpdir/opencode.real" ]; then BIN="$tmpdir/opencode.real"
  else die "Unexpected archive contents (opencode not found inside)."; fi
  chmod 755 "$BIN"

  ts="$(date +%Y%m%d-%H%M%S)"
  if [ -f "$PAYLOAD" ]; then
    say "Backing up the old version (${CUR:-old}) -> $BACKUP_DIR/opencode-${CUR:-old}-$ts.tar.gz"
    tar -czf "$BACKUP_DIR/opencode-${CUR:-old}-$ts.tar.gz" -C "$PAYLOAD_DIR" opencode.real
    cp -f "$PAYLOAD" "$tmpdir/opencode.real.bak"
  fi
  cp -f "$BIN" "$PAYLOAD.new" && chmod 755 "$PAYLOAD.new" && mv -f "$PAYLOAD.new" "$PAYLOAD"
  [ -x "$LAUNCHER" ] || install_our_launcher
  prune_backups
fi

step "5/6 Verification"
GOT="$(installed_version)"; [ -n "$GOT" ] || GOT="$(payload_version)"
if [ "$GOT" != "$LATEST_NOV" ]; then
  if [ -f "$tmpdir/opencode.real.bak" ]; then
    cp -f "$tmpdir/opencode.real.bak" "$PAYLOAD" && chmod 755 "$PAYLOAD"
    say "${c_warn}Old payload restored (rollback).${c_off}"
  fi
  die "Verification failed (got: ${GOT:-empty}, expected: $LATEST_NOV)."
fi

step "6/6 Plugins & cross-session memory"
OC_DIR="$HOME/.config/opencode"
PLUGIN_DIR="$OC_DIR/plugins"
STAGE="$SELF_DIR"
[ -n "$STAGE" ] || STAGE="$(mktemp -d "$PREFIX/tmp/oc-mem.XXXXXX")"

install_plugin() {
  local name="$1" src="$STAGE/plugins/$1" dst="$PLUGIN_DIR/$1" backup
  if [ ! -s "$src" ]; then
    fetch_file "plugins/$name" "$src" || { say "${c_warn}failed to download plugins/$name${c_off}"; return 1; }
  fi
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    if [ "$name" = "memory.js" ]; then
      backup="$dst.v1.bak"
      [ -e "$backup" ] && backup="$dst.v1.$(date +%Y%m%d%H%M%S).bak"
    else
      backup="$dst.bak-$(date +%Y%m%d%H%M%S)"
    fi
    cp "$dst" "$backup"
    say "Old plugin backed up to $backup"
  fi
  cp "$src" "$dst"
  chmod 600 "$dst" 2>/dev/null || true
  say "Plugin installed: $dst"
}

if [ "$NO_PLUGIN" -eq 1 ]; then
  say "Bundled plugins skipped (--no-plugin)"
else
  mkdir -p "$PLUGIN_DIR"
  install_plugin memory.js || true
  install_plugin session-title.js || true
  install_plugin update-notice.js || true
fi

if [ "$WITH_MEMORY" -eq 1 ]; then
  mkdir -p "$OC_DIR/bin"
  DIGEST="$OC_DIR/bin/session-digest.py"
  DIGEST_SRC="$STAGE/plugins/session-digest.py"
  if [ ! -s "$DIGEST_SRC" ]; then
    fetch_file "plugins/session-digest.py" "$DIGEST_SRC" || say "${c_warn}failed to download session-digest.py${c_off}"
  fi
  if [ -s "$DIGEST_SRC" ]; then
    cp "$DIGEST_SRC" "$DIGEST"
    sed -i "1s|^#!.*|#!$PREFIX/bin/python3|" "$DIGEST"
    chmod 755 "$DIGEST"
    say "Session summary generator: $DIGEST"
  fi

  # kuota: estimated remaining free-model quota (reads the local databases only)
  KUOTA="$OC_DIR/bin/kuota"
  KUOTA_SRC="$STAGE/plugins/kuota.py"
  if [ ! -s "$KUOTA_SRC" ]; then
    fetch_file "plugins/kuota.py" "$KUOTA_SRC" || say "${c_warn}failed to download kuota.py${c_off}"
  fi
  if [ -s "$KUOTA_SRC" ]; then
    cp "$KUOTA_SRC" "$KUOTA"
    sed -i "1s|^#!.*|#!$PREFIX/bin/python3|" "$KUOTA"
    chmod 755 "$KUOTA"
    mkdir -p "$PREFIX/bin"
    ln -sf "$KUOTA" "$PREFIX/bin/kuota"
    say "Quota estimator: $KUOTA (command: kuota)"
  fi

  # Templates are only installed when missing — the user's memory must not be overwritten.
  for f in MEMORY.md AGENTS.md opencode.jsonc; do
    if [ -f "$OC_DIR/$f" ]; then
      say "already exists, skipped: $OC_DIR/$f"
      continue
    fi
    src="$STAGE/memory/$f"
    if [ ! -s "$src" ]; then
      fetch_file "memory/$f" "$src" || { say "${c_warn}failed to fetch memory/$f${c_off}"; continue; }
    fi
    cp "$src" "$OC_DIR/$f"
    if [ "$f" = "opencode.jsonc" ]; then
      sed -i "s|/data/data/com.termux/files/home|$HOME|g" "$OC_DIR/$f"
    fi
  done
  [ -f "$OC_DIR/RECENT.md" ] || printf '# RECENT\n\nNo sessions recorded yet.\n' >"$OC_DIR/RECENT.md"
  if [ -x "$DIGEST" ]; then
    python3 "$DIGEST" >/dev/null 2>&1 || true
  fi
  say "Memory/templates, rules, and instructions are ready in $OC_DIR"

  if ! grep -q "_oc_refresh_digest" "$HOME/.bashrc" 2>/dev/null; then
    [ -f "$HOME/.bashrc" ] || : >"$HOME/.bashrc"
    cat >>"$HOME/.bashrc" <<'EOS'

# --- refresh the session summary before opencode starts (install.sh) ---
_oc_refresh_digest() {
  [ -x "$HOME/.config/opencode/bin/session-digest.py" ] || return 0
  python3 "$HOME/.config/opencode/bin/session-digest.py" >/dev/null 2>&1
}
# V1 keeps its own database. Drop the V2 XDG_* values so starting V1 from a V2
# shell cannot point it at the V2 database ("no session table", blank screen).
_oc_tty_repair() {
  [ -t 1 ] || return 0
  stty sane 2>/dev/null
  printf '\033[?1049l\033[?25h\033[0m'
}
opencode() {
  _oc_refresh_digest
  local rc=0
  ( unset XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; command opencode "$@" )
  rc=$?
  [ "$rc" -ne 0 ] && _oc_tty_repair
  return "$rc"
}
opencode-v2() {
  _oc_refresh_digest
  local rc=0
  command opencode-v2 "$@"
  rc=$?
  [ "$rc" -ne 0 ] && _oc_tty_repair
  return "$rc"
}
EOS
    say "~/.bashrc: session summary refreshes automatically"
  fi
fi
[ -n "$SELF_DIR" ] || rm -rf "$STAGE"

say "${c_ok}opencode $GOT is ready to use.${c_off}"
say ""
say "Try it now:      opencode"
say "Check version:   opencode --version"
say "Upgrade again:   bash install.sh --upgrade"
say "Remove:          bash uninstall.sh"
