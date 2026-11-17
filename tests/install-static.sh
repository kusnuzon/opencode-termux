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

printf '\n%s passed · %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
