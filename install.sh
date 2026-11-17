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

# --- progress-bar begin (synced from codemux/lib/progress-bar.sh) ---
# progress_bar <percent> [width] [label] — plain ASCII bar + percentage.
# Out-of-range and non-numeric input is clamped, never an error: the callers
# use it inside command substitution, where an error would print garbage.
progress_bar() {
  local pct="${1:-0}" width="${2:-24}" label="${3:-}"
  local filled blank bar dash
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  [ "$width" -gt 0 ] 2>/dev/null || width=24
  filled=$((pct * width / 100))
  blank=$((width - filled))
  printf -v bar '%*s' "$filled" ''
  printf -v dash '%*s' "$blank" ''
  bar="${bar// /#}"
  dash="${dash// /-}"
  printf '[%s%s] %3d%%' "$bar" "$dash" "$pct"
  [ -n "$label" ] && printf '  %s' "$label"
  return 0
}

# progress_step <current> <total> <label> — a numbered bar line.
progress_step() {
  progress_bar "$((10#${1:-0} * 100 / 10#${2:-1}))" 24 "${1:-0}/${2:-0} ${3:-}"
}
# --- progress-bar end ---

# --- tmux-config begin (synced from codemux/lib/tmux-config.sh) ---
# Managed tmux config: dark status bar (tmux 3.8 defaults to green on black),
# a 20-column tab strip you can tap, plus the extended keys the pi TUI needs.
# Everything outside the markers belongs to the user and is never touched.
#
# The strip is one tmux window per tab:
#   " 0:menu          ✕ │ "  tap the name to switch, tap ✕ to close it
#   "  keep    │ close   "  the same tab while a close waits for an answer
# and a single heavy "✚" button follows the last tab, so it walks along with
# the strip instead of sitting far away at the right end of the bar. The glyph
# is a heavy cross rather than an ASCII "+": bigger than a plain plus, but it
# does not fill the whole cell, so the bar stays calm.
#
# Clicks are read from #{mouse_status_range}, never from #{mouse_x}: tmux scrolls
# the window list by itself when the tabs do not fit, so a column count would
# point at the wrong tab. Every tap area is a #[range=user|...] region instead,
# which survives scrolling and any change of width.
#
# The handler is a script (codemux installs it next to the menu) because a
# .tmux.conf cannot define a function. Each binding ends with `exit 0`: tmux
# prints "'<script>' returned 1" on the message line for a failing run-shell,
# and that looks like a broken strip.
TMUXCONF_BEGIN='# --- codemux:tmux begin (managed; edits inside this block are overwritten) ---'
TMUXCONF_END='# --- codemux:tmux end ---'

# tmuxconf_block — print the managed block, markers included.
tmuxconf_block() {
  cat <<TMUXCONF
$TMUXCONF_BEGIN
# pi relies on extended keys so Shift+Enter and friends reach the TUI.
set -g extended-keys on
set -g extended-keys-format csi-u

# tmux renders italics as reverse video (light background, dark text) whenever
# default-terminal starts with "screen" — a legacy GNU screen compatibility hack
# in tty_set_italics(). pi draws its thinking text in italics, so screen-*
# turned every thinking block into an unreadable light highlight. tmux-256color
# exists in Termux's terminfo and keeps italics real.
set -g default-terminal "tmux-256color"

# Tap a tab on the status bar to switch to it (tmux's own binding).
set -g mouse on

# Status bar on top, pure black so an AMOLED screen stays black. The window list
# stays the plain "index: name" strip — no custom formats to mis-render.
set -g status-position top
set -g status-style "bg=#000000,fg=#c0c0c0"
set -g status-left ""
set -g window-status-separator ""
# The menu names each tab, so tmux must not rename it back to the command.
set -g automatic-rename off

# One tab = 20 columns, always: a space, the index + a name cut to 12 columns
# (p15 pads the slot, so a short name never shrinks the target under a finger),
# then the ✕ button and the separator of that tab.
set -g window-status-format "#{?#{==:#{window_index},#{@closepending}},#[range=user|k#{window_index}]#[fg=#c0c0c0]  keep    #[range=user|x#{window_index}]#[fg=#5f6368]│#[fg=#ff6b6b#,bold] close   #[default], #[range=user|t#{window_index}]#{p15:#{window_index}:#{=12:window_name}}#[range=user|c#{window_index}] ✕ #[range=user|t#{window_index}]#[fg=#5f6368]│#[default]}#{?#{==:#{window_index},#{e|-|:#{session_windows},1}},#[range=user|new]#[fg=#e0e0e0#,bold] ✚ #[default],#[default]}"
set -g window-status-current-format "#{?#{==:#{window_index},#{@closepending}},#[range=user|k#{window_index}]#[fg=#c0c0c0]  keep    #[range=user|x#{window_index}]#[fg=#5f6368]│#[fg=#ff6b6b#,bold] close   #[default],#[fg=#ffffff#,bg=#2a2a2a#,bold] #[range=user|t#{window_index}]#{p15:#{window_index}:#{=12:window_name}}#[range=user|c#{window_index}] ✕ #[range=user|t#{window_index}] #[default]}#{?#{==:#{window_index},#{e|-|:#{session_windows},1}},#[range=user|new]#[fg=#e0e0e0#,bold] ✚ #[default],#[default]}"
set -g window-status-current-style "default"
# The "✚" button lives on the last tab (see the formats above), so the right
# end of the bar stays empty.
set -g status-right ""

bind-key -n MouseDown1Status "run-shell \"sh \$HOME/.config/codemux/tabctl.sh tap '#{mouse_status_range}' >/dev/null 2>&1; exit 0\""
set -g pane-border-style "fg=#2a2a2a"
set -g pane-active-border-style "fg=#5f6368"
# Warm near-black pane background (#11100E): cells pi draws with the default
# background pick this up, so long reading sessions stay easy on the eyes
# while explicit backgrounds (selections, tool boxes) keep their own colors.
set -g window-style "bg=#11100E"
set -g window-active-style "bg=#11100E"
set -g message-style "bg=#000000,fg=#e0e0e0"
set -g message-command-style "bg=#000000,fg=#e0e0e0"

# Copy-mode (scrolling back with the wheel) and text selection: tmux's default
# paints the copy-mode cursor and the selection bright yellow, which sits like
# a glaring highlight over dim text on a black screen and makes it unreadable.
# Dark selection with white text keeps every highlighted character readable.
set -g mode-style "fg=#ffffff,bg=#5f6368"
set -g copy-mode-match-style "fg=#000000,bg=#8ab4f8"
set -g copy-mode-current-match-style "fg=#000000,bg=#e0e0e0"
$TMUXCONF_END
TMUXCONF
}

# tmuxconf_slice <file> — print the managed block found in <file>, markers
# included; prints nothing when the file has no markers. Never fails.
tmuxconf_slice() {
  local file="$1" line inside=0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "$TMUXCONF_BEGIN" ]; then
      inside=1
      printf '%s\n' "$line"
      continue
    fi
    if [ "$inside" -eq 1 ] && [ "$line" = "$TMUXCONF_END" ]; then
      printf '%s\n' "$line"
      inside=0
      continue
    fi
    [ "$inside" -eq 1 ] && printf '%s\n' "$line"
  done <"$file"
  return 0
}

# tmuxconf_tabctl <path> — print the click handler for the tab strip.
# A .tmux.conf cannot define a function and a strip button that does nothing is
# worse than no button, so the handler ships inside this block: the three repos
# install the same script and V1/V2 need no extra file of their own.
#   tap <range>   t<i> switch, c<i> ask, k<i> keep, x<i> close, new add a tab
# Any non-zero exit makes tmux print "'<script>' returned N" over the whole
# status bar, so every path ends with `exit 0`.
tmuxconf_tabctl() {
  cat <<'TABCTL'
#!/bin/sh
# codemux tabctl — the mouse actions of the .tmux.conf tab strip.
# Installed by codemux (lib/tmux-config.sh). Do not edit by hand.
#
# The confirmation state is the session option @closepending: the tab format
# draws that one tab as two buttons, and the buttons are ranges (k…/x…), so this
# script never has to know where a tab sits on the screen. Taps are resolved
# from #{mouse_status_range}, never from a column count: tmux scrolls the window
# list by itself once the tabs overflow a column count would be wrong anyway.

set -u
action="${1:-}"
range="${2:-}"

sess="$(tmux display-message -p '#S' 2>/dev/null)" || exit 0
[ -n "$sess" ] || exit 0

clear_pending() { tmux set-option -u -t "$sess" @closepending >/dev/null 2>&1; }
window_count() { tmux list-windows -t "$sess:" 2>/dev/null | wc -l; }
last_tab() { tmux display-message -t "$sess" 'Last tab - keeping it open' >/dev/null 2>&1; }

case "$action" in
  new)
    clear_pending
    tmux new-window -t "$sess:" >/dev/null 2>&1
    ;;
  tap)
    idx="${range#?}"
    # Only a plain index is ever passed on to tmux as a window target.
    case "$idx" in
      '' | *[!0-9]*) idx="" ;;
    esac
    case "$range" in
      new)
        clear_pending
        tmux new-window -t "$sess:" >/dev/null 2>&1
        ;;
      t*)
        clear_pending
        [ -n "$idx" ] && tmux select-window -t "$sess:$idx" >/dev/null 2>&1
        ;;
      c*)
        clear_pending
        if [ "$(window_count)" -le 1 ]; then
          last_tab
        elif [ -n "$idx" ]; then
          tmux set-option -t "$sess" @closepending "$idx" >/dev/null 2>&1
        fi
        ;;
      k*)
        clear_pending
        ;;
      x*)
        clear_pending
        if [ "$(window_count)" -le 1 ]; then
          last_tab
        elif [ -n "$idx" ]; then
          tmux kill-window -t "$sess:$idx" >/dev/null 2>&1
          # keep the indexes dense, so a tab number is always its position
          tmux move-window -r -t "$sess:" >/dev/null 2>&1
        fi
        ;;
    esac
    ;;
esac
exit 0
TABCTL
}

tmuxconf_tabctl_path() { printf '%s' "${HOME:-}/.config/codemux/tabctl.sh"; }

# tmuxconf_tabctl_state — ok, stale or missing for the installed handler.
tmuxconf_tabctl_state() {
  local dst want
  dst="$(tmuxconf_tabctl_path)"
  [ -f "$dst" ] || { printf 'missing'; return 0; }
  want="$(tmuxconf_tabctl)"
  if [ "$(cat "$dst" 2>/dev/null)" = "$want" ]; then
    printf 'ok'
  else
    printf 'stale'
  fi
  return 0
}

# tmuxconf_tabctl_install — write the handler, idempotent.
tmuxconf_tabctl_install() {
  local dst tmp
  dst="$(tmuxconf_tabctl_path)"
  [ -n "$dst" ] || return 1
  [ "$(tmuxconf_tabctl_state)" = ok ] && return 0
  mkdir -p "${dst%/*}" 2>/dev/null || return 1
  tmp="$dst.tmp.$$"
  tmuxconf_tabctl >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  chmod 700 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# tmuxconf_conf_state <file> — ok, stale or missing for the managed block alone.
tmuxconf_conf_state() {
  local file="${1:-$HOME/.tmux.conf}" want have
  if [ ! -f "$file" ]; then
    printf 'missing'
    return 0
  fi
  grep -qxF "$TMUXCONF_BEGIN" "$file" 2>/dev/null || {
    printf 'missing'
    return 0
  }
  want="$(tmuxconf_block)"
  have="$(tmuxconf_slice "$file")"
  if [ "$want" = "$have" ]; then
    printf 'ok'
  else
    printf 'stale'
  fi
  return 0
}

# tmuxconf_state <file> — the block AND the click handler it binds to. A strip
# whose buttons cannot run anything is not "ok", so that counts as stale.
tmuxconf_state() {
  local file="${1:-$HOME/.tmux.conf}" cstate
  cstate="$(tmuxconf_conf_state "$file")"
  if [ "$cstate" != "ok" ]; then
    printf '%s' "$cstate"
    return 0
  fi
  if [ "$(tmuxconf_tabctl_state)" = ok ]; then
    printf 'ok'
  else
    printf 'stale'
  fi
  return 0
}

# tmuxconf_conf_write <file> — make the managed block present and current.
# Creates the file, appends the block to a user file, or replaces the block
# in place; the previous content is backed up before any change. Returns 0
# when the block is up to date afterwards, 1 when it could not be written.
tmuxconf_conf_write() {
  local conf="${1:-$HOME/.tmux.conf}" state block tmp line skip bak
  state="$(tmuxconf_conf_state "$conf")"
  [ "$state" = "ok" ] && return 0

  mkdir -p "${conf%/*}" 2>/dev/null || return 1
  block="$(tmuxconf_block)" || return 1

  if [ -f "$conf" ]; then
    bak="$conf.bak-tmuxconf-$(date +%Y%m%d%H%M%S)"
    cp "$conf" "$bak" 2>/dev/null || true
  fi

  case "$state" in
    missing)
      if [ -s "$conf" ]; then
        # keep the user's file intact, add a blank line as separator
        [ -z "$(tail -c 1 "$conf" 2>/dev/null)" ] || { printf '\n' >>"$conf"; } 2>/dev/null || return 1
        { printf '%s\n' "$block" >>"$conf"; } 2>/dev/null || return 1
      else
        { printf '%s\n' "$block" >"$conf"; } 2>/dev/null || return 1
      fi
      return 0 ;;
    stale)
      tmp="$conf.tmuxconf.$$"
      skip=0
      : >"$tmp" || return 1
      while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$TMUXCONF_BEGIN" ]; then
          printf '%s\n' "$block" >>"$tmp"
          skip=1
          continue
        fi
        if [ "$skip" -eq 1 ] && [ "$line" = "$TMUXCONF_END" ]; then
          skip=0
          continue
        fi
        [ "$skip" -eq 1 ] && continue
        printf '%s\n' "$line" >>"$tmp"
      done <"$conf"
      mv -f "$tmp" "$conf" || {
        rm -f "$tmp"
        return 1
      }
      return 0 ;;
  esac
  return 1
}

# tmuxconf_install [file] — write the block and the click handler it binds to.
tmuxconf_install() {
  tmuxconf_conf_write "${1:-$HOME/.tmux.conf}" || return 1
  tmuxconf_tabctl_install || return 1
  return 0
}
# --- tmux-config end ---

step() {
  local title="$1" pct
  if [[ "$title" =~ ^([0-9]+)/([0-9]+) ]]; then
    pct=$((10#${BASH_REMATCH[1]} * 100 / 10#${BASH_REMATCH[2]}))
    printf '\n%s' "$c_b"
    progress_bar "$pct" 24 "$title"
    printf '%s' "$c_off"
  else
    printf '\n%s=== %s ===%s\n' "$c_b" "$title" "$c_off"
  fi
}

say()  { printf '%s\n' "$*"; }
die()  { printf '%s%s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check)    MODE="check"; shift ;;
    --upgrade)  MODE="upgrade"; shift ;;
    --dry-run)  MODE="dry-run"; shift ;;
    --version)
      TARGET="${2:-}"
      [ -n "$TARGET" ] || die "--version needs a value, e.g. --version 1.19.5"
      shift 2 ;;
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
    gh api "$1" 2>/dev/null && return 0
  fi
  # gh can still fail (rate limit, token expired) — curl is the fallback.
  curl -fsSL -H 'Accept: application/vnd.github+json' "$1"
}

# download_url <url> <dest> [accept] [progress] — curl → wget → python.
# progress=1 shows curl's bar + percentage on a terminal (used for the big
# payload). A partial curl download is never accepted: a timeout can leave a
# non-empty .part file, and the checksum would then fail later.
download_url() {
  local url="$1" dest="$2" accept="${3:-}" progress="${4:-0}" part="$2.part" rc=0
  mkdir -p "$(dirname "$dest")" || return 1
  rm -f "$part"
  if [ "$progress" = "1" ] && [ -t 2 ]; then
    if [ -n "$accept" ]; then
      curl -fL --progress-bar --max-time 900 -H "Accept: $accept" "$url" -o "$part"
    else
      curl -fL --progress-bar --max-time 900 "$url" -o "$part"
    fi
    rc=$?
  else
    if [ -n "$accept" ]; then
      curl -fsSL --max-time 900 -H "Accept: $accept" "$url" -o "$part" 2>/dev/null
    else
      curl -fsSL --max-time 900 "$url" -o "$part" 2>/dev/null
    fi
    rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ -s "$part" ]; then mv -f "$part" "$dest"; return 0; fi
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
BASE_PKGS="curl tar unzip gzip coreutils ca-certificates jq python git sqlite wget openssh gh ncdu htop tmux"
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

# Under pipefail a failed api_get would make the assignment below kill the
# script through `set -e` before the friendly die message is reached.
LATEST="$(latest_tag || true)"
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
  say "3. launcher: opencode dpkg package from the termuxvoid repo (official payload + glibc wrapper)"
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

# Dark tmux theme + the extended keys the pi TUI needs. The synced block lives
# above; it only touches its own marked region and backs up whatever
# ~/.tmux.conf already held.
if tmuxconf_install "$HOME/.tmux.conf"; then
  say "  $HOME/.tmux.conf: dark tmux theme ok"
else
  say "! could not write ~/.tmux.conf (theme skipped)"
fi
step "2/6 glibc runtime (required: the opencode binary is glibc, Android is bionic)"
pkg install -y glibc-repo >/dev/null 2>&1 || true
apt_update || true
pkg install -y glibc termux-exec-glibc || die "failed to install glibc/termux-exec-glibc"
have_loader || die "glibc loader not found: $PREFIX/glibc/lib/ld-linux-aarch64.so.1"
# Order matters: glibc first, then check curl again.
heal_curl || say "! curl is still broken after glibc"

step "3/6 Launcher"
# V1 must come from the TermuxVoid APT repository: its opencode package downloads
# the official upstream payload, verifies the sha256, and compiles a tiny C
# wrapper for the Termux glibc loader. That wrapper is the method proven to work
# on this device, so it is the default. OPENCODE_USE_SCRIPT=1 opts into the small
# shell launcher bundled with this repo instead (no clang/LLVM dependency).
if [ "${OPENCODE_USE_SCRIPT:-0}" = "1" ] || ! command -v pkg >/dev/null 2>&1; then
  install_our_launcher
else
  TL="$PREFIX/etc/apt/sources.list.d/termuxvoid.list"
  KEYDIR="$PREFIX/etc/apt/trusted.gpg.d"
  mkdir -p "$(dirname "$TL")" "$KEYDIR"
  printf 'deb [arch=all] https://termuxvoid.github.io/repo termuxvoid main\n' > "$TL"
  say "termuxvoid repo configured (signed)."
  if ! download_url "https://github.com/termuxvoid/repo/raw/main/assets/termuxvoid.gpg" "$KEYDIR/termuxvoid.gpg" 2>/dev/null; then
    say "! warning: could not download the termuxvoid GPG key; using trusted=yes for this install"
    printf 'deb [arch=all trusted=yes] https://termuxvoid.github.io/repo termuxvoid main\n' > "$TL"
  fi
  apt_update || say "! warning: 'pkg update' failed after adding the termuxvoid repo"
  # dpkg refuses/warns when an unowned launcher sits at the same path.
  if [ -e "$LAUNCHER" ] && ! dpkg -S "$LAUNCHER" >/dev/null 2>&1; then
    rm -f "$LAUNCHER"
  fi
  pkg install -y opencode || true
  if dpkg -s opencode >/dev/null 2>&1; then
    apt-mark hold opencode || true
    say "opencode $(dpkg-query -W -f='${Version}' opencode 2>/dev/null || true) installed from termuxvoid."
    say "apt-mark hold opencode -> safe from 'pkg upgrade' overwriting the payload."
  else
    say "! termuxvoid package unavailable; falling back to the repo script launcher."
    install_our_launcher
  fi
fi
CUR="$(installed_version)"; [ -n "$CUR" ] || CUR="$(payload_version)"

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
  if download_url "$MIRROR_URL" "$tmpdir/pkg.tar.gz" "" 1; then
    say "Source: mirror in repo $REPO"
  else
    say "Mirror unavailable, fetching from upstream..."
    download_url "$UP_URL" "$tmpdir/pkg.tar.gz" "" 1 || die "Failed to download $UP_URL"
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

  # quota: estimated remaining free-model quota (reads the local databases only)
  QUOTA="$OC_DIR/bin/quota"
  QUOTA_SRC="$STAGE/plugins/quota.py"
  if [ ! -s "$QUOTA_SRC" ]; then
    fetch_file "plugins/quota.py" "$QUOTA_SRC" || say "${c_warn}failed to download quota.py${c_off}"
  fi
  if [ -s "$QUOTA_SRC" ]; then
    cp "$QUOTA_SRC" "$QUOTA"
    sed -i "1s|^#!.*|#!$PREFIX/bin/python3|" "$QUOTA"
    chmod 755 "$QUOTA"
    mkdir -p "$PREFIX/bin"
    ln -sf "$QUOTA" "$PREFIX/bin/quota"
    # Older releases shipped this as `kuota`; drop the stale copies.
    rm -f "$PREFIX/bin/kuota" "$OC_DIR/bin/kuota"
    say "Quota estimator: $QUOTA (command: quota)"
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
# The repair always runs (not only on error): a clean TUI exit can still leave
# the alt-screen up, which looks like a frozen terminal.
_oc_tty_repair() {
  local t=""
  if { printf '' >/dev/tty; } 2>/dev/null; then t=/dev/tty
  elif [ -t 1 ]; then t=/dev/stdout
  else return 0
  fi
  # Close a control sequence a killed TUI left open, then undo XOFF (a stuck
  # XOFF swallows every following byte, which also looks like a freeze).
  printf '\007\033\\\033\\\017' >"$t" 2>/dev/null
  stty sane 2>/dev/null <"$t" || true
  # alt-screen, mouse, focus, bracketed paste, cursor-key mode, charset, then a
  # full reset (RIS) as the hammer, and a forced redraw.
  printf '\033[?1049l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1004l\033[?2004l\033[?1l\033>\033c\033[!p\033[2J\033[H\033[0m\033[?25h' >"$t" 2>/dev/null
}
opencode() {
  _oc_refresh_digest
  local rc=0
  ( unset XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; command opencode "$@" )
  rc=$?
  _oc_tty_repair
  return "$rc"
}
opencode-v2() {
  _oc_refresh_digest
  local rc=0
  command opencode-v2 "$@"
  rc=$?
  _oc_tty_repair
  return "$rc"
}
EOS
    say '$HOME/.bashrc: session summary refreshes automatically'
  fi
fi
[ -n "$SELF_DIR" ] || rm -rf "$STAGE"

say "${c_ok}opencode $GOT is ready to use.${c_off}"
say ""
say "Try it now:      opencode"
say "Check version:   opencode --version"
say "Upgrade again:   bash install.sh --upgrade"
say "Remove:          bash uninstall.sh"
