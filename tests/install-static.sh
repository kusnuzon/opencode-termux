#!/usr/bin/env bash
# tests/install-static.sh — structural assertions for install.sh.
#
# These bugs were found by audit and none of them is visible to a dry run:
#   * ensure_base_deps was glued onto a comment line, so the "1/6" step never
#     installed anything on a fresh Termux
#   * a failed `latest_tag` killed the script through set -e before the friendly
#     die message ("LATEST=$(latest_tag)")
#   * the ~/.bashrc hook repaired the terminal only when opencode exited with an
#     error, while a clean TUI exit can leave the alt-screen up (frozen screen)
#   * the quota estimator was still installed under the old `kuota` name
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# 1. ensure_base_deps must be called as a command, not live inside a comment.
if grep -q '^ensure_base_deps$' install.sh; then
  ok "ensure_base_deps is actually called"
else
  bad "ensure_base_deps is never called (glued into a comment?)"
fi

# 2. a failed latest_tag must not kill the script before its die message.
if grep -q 'LATEST="$(latest_tag || true)"' install.sh; then
  ok "latest_tag failure is caught, die message survives"
else
  bad "LATEST=\$(latest_tag) lets set -e exit without a message"
fi

# 3. the bashrc hook: repair runs after every exit, and resets the modes a TUI
#    leaves behind (alt-screen, mouse, bracketed paste) — not just stty.
hook="$(sed -n '/^# --- refresh the session summary before opencode starts/,/^EOS$/p' install.sh)"
if printf '%s' "$hook" | grep -qF '\033[?1049l'; then
  ok "hook resets the alt-screen"
else
  bad "hook does not leave the alt-screen"
fi
if printf '%s' "$hook" | grep -qF '\033[?1000l'; then
  ok "hook resets the mouse modes"
else
  bad "hook does not reset the mouse modes"
fi
if printf '%s' "$hook" | grep -qF '[ "$rc" -ne 0 ] && _oc_tty_repair'; then
  bad "repair is still gated on a non-zero exit code"
else
  ok "repair runs after every opencode exit"
fi
if printf '%s' "$hook" | grep -qF 'XOFF'; then
  ok "hook documents the XOFF case"
else
  bad "hook lost the XOFF note"
fi

# 4. the quota estimator uses the current name; the legacy one is only removed.
if grep -qF 'ln -sf "$QUOTA" "$PREFIX/bin/quota"' install.sh &&
  grep -qF 'rm -f "$PREFIX/bin/kuota"' install.sh &&
  ! grep -qF 'ln -sf "$KUOTA"' install.sh; then
  ok "quota estimator installed as 'quota', legacy kuota dropped"
else
  bad "quota/kuota naming regressed"
fi
[ -f plugins/quota.py ] && ok "plugins/quota.py exists" || bad "plugins/quota.py missing"
[ -f plugins/kuota.py ] && bad "stale plugins/kuota.py still in the repo" || ok "no stale plugins/kuota.py"

# 5. --version without a value must be rejected, not silently mean "latest".
if grep -qF '"--version needs a value' install.sh; then
  ok "--version without a value is rejected"
else
  bad "--version without a value is silently ignored"
fi

# 6. prune_backups must survive an empty backup dir: a fresh install has no
#    backups, the glob matches nothing, ls exits 2 — and with set -euo pipefail
#    that used to kill the installer right after the payload was written, so
#    verification, plugins and memory never ran. Run the real function.
pb="$(sed -n '/^prune_backups() {/,/^}/p' install.sh)"
tmpb="$(mktemp -d)"
if BACKUP_DIR="$tmpb" KEEP_BACKUPS=2 bash -c \
  'set -Eeuo pipefail; eval "$1"; prune_backups; echo PRUNE-RAN' _ "$pb" | grep -q PRUNE-RAN; then
  ok "prune_backups survives an empty backup dir"
else
  bad "prune_backups kills the installer when no backups exist yet"
fi
rm -rf "$tmpb"

# 7. upgrade.sh accepts the bare version its own usage documents.
if grep -qF -- 'exec bash "$DIR/install.sh" --upgrade --version "$@"' upgrade.sh; then
  ok "upgrade.sh maps a bare version to --version"
else
  bad "upgrade.sh rejects the bare version its own usage documents"
fi

# 8. prune_backups must also drop backups whose version was unknown
#    ("opencode-old-*"): those are the oldest ones and a digits-only glob
#    would leave them on disk forever. Run the real function.
pb="$(sed -n '/^prune_backups() {/,/^}/p' install.sh)"
tmpb="$(mktemp -d)"
mkdir -p "$tmpb/bk"
touch "$tmpb/bk/opencode-1.19.5-20260101.tar.gz" \
  "$tmpb/bk/opencode-1.19.4-20260102.tar.gz" \
  "$tmpb/bk/opencode-old-20251231.tar.gz"
if BACKUP_DIR="$tmpb/bk" KEEP_BACKUPS=2 bash -c \
  'set -Eeuo pipefail; eval "$1"; prune_backups' _ "$pb" &&
  [ ! -e "$tmpb/bk/opencode-old-20251231.tar.gz" ]; then
  ok "prune_backups also prunes opencode-old-* backups"
else
  bad "prune_backups leaves opencode-old-* backups forever"
fi
rm -rf "$tmpb"

# 9. the python download fallback must stream to disk, not read the whole
#    ~200 MB payload into RAM (a phone OOMs on that).
du="$(sed -n '/^download_url()/,/^}/p' install.sh)"
if printf '%s' "$du" | grep -q 'shutil.copyfileobj' &&
   ! printf '%s' "$du" | grep -q 'urlopen(req, timeout=60).read()'; then
  ok "python download fallback streams the payload to disk"
else
  bad "python download fallback reads the whole payload into RAM"
fi

# 10. the plugin stage must only reuse the directory next to install.sh when
#     it is the real repo (has plugins/); otherwise a stale copy from an
#     arbitrary directory would be installed silently.
if grep -qF -- '[ -d "$SELF_DIR/plugins" ]' install.sh; then
  ok "plugin stage is guarded against a stale non-repo directory"
else
  bad "plugin stage trusts any directory install.sh sits in"
fi

printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
