#!/usr/bin/env bash
# tests/launcher.sh — exercise $PREFIX/bin/opencode (opencode-launcher) offline.
#
# The launcher is a generated file (sed replaces @PREFIX@), so the tests build it
# into a sandbox and let fake loader/payload scripts report the environment the
# real binary would see. What is pinned here:
#   * the bionic termux-exec preload never reaches the glibc binary
#     (that preload is what makes V1 die with "version `LIBC' not found")
#   * XDG_* from a V2 shell is dropped (V1 has its own database)
#   * the glibc lib dir is on LD_LIBRARY_PATH and in --library-path
#   * arguments are forwarded and the payload's exit code comes back
#
# shellcheck shell=bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

BASE="${TMPDIR:-/tmp}"
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}/tmp" ]; then BASE="$PREFIX/tmp"; fi
SANDBOX="$BASE/opencode-termux-launcher-$$"
BASH_BIN="$(command -v bash)"
rm -rf "$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/prefix/bin" "$SANDBOX/prefix/glibc/lib" \
  "$SANDBOX/prefix/share/opencode" "$SANDBOX/prefix/etc/tls"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# --- install the launcher into the sandbox, the same way install.sh does ------
sed "s|@PREFIX@|$SANDBOX/prefix|g" opencode-launcher >"$SANDBOX/prefix/bin/opencode"
chmod 755 "$SANDBOX/prefix/bin/opencode"

# --- fake glibc loader and payload -------------------------------------------
# The loader prints what it inherited, skips --library-path <dir>, and execs the
# payload with the remaining arguments (mirroring the real loader contract).
cat >"$SANDBOX/prefix/glibc/lib/ld-linux-aarch64.so.1" <<'EOS'
#!/usr/bin/env bash
printf 'loader preload=%s audit=%s libpath=%s xdg=%s\n' \
  "${LD_PRELOAD:-none}" "${LD_AUDIT:-none}" "${LD_LIBRARY_PATH:-none}" "${XDG_DATA_HOME:-none}"
if [ "${1:-}" = "--library-path" ]; then
  printf 'library-path=%s\n' "${2:-}"
  shift 2
fi
exec "$@"
EOS
chmod 755 "$SANDBOX/prefix/glibc/lib/ld-linux-aarch64.so.1"

cat >"$SANDBOX/prefix/share/opencode/opencode.real" <<'EOS'
#!/usr/bin/env bash
printf 'real args=%s tls=%s\n' "$*" "${SSL_CERT_FILE:-none}"
exit "${REAL_RC:-0}"
EOS
chmod 755 "$SANDBOX/prefix/share/opencode/opencode.real"

# /usr/bin/env does not exist on Android, so the fake scripts use the bash the
# suite is running under (on Termux that is $PREFIX/bin/bash).
for stub in "$SANDBOX/prefix/glibc/lib/ld-linux-aarch64.so.1" \
  "$SANDBOX/prefix/share/opencode/opencode.real"; do
  sed -i "1s|.*|#!$BASH_BIN|" "$stub"
done

run_launcher() {
  env -i \
    HOME="$SANDBOX/home" PATH="$PATH" \
    PREFIX="$SANDBOX/prefix" \
    LD_PRELOAD=/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so \
    LD_AUDIT=/tmp/audit.so \
    XDG_DATA_HOME="$SANDBOX/v2/data" \
    XDG_STATE_HOME="$SANDBOX/v2/state" \
    XDG_CACHE_HOME="$SANDBOX/v2/cache" \
    REAL_RC="${1:-0}" \
    "$BASH_BIN" "$SANDBOX/prefix/bin/opencode" run --model x 2>&1
}

export BASH_BIN

# --- cases -------------------------------------------------------------------
out="$(run_launcher 0)" || bad "launcher exited non-zero on a clean payload"

case "$out" in
  *"preload=none"*) ok "the bionic LD_PRELOAD is dropped before exec" ;;
  *) bad "LD_PRELOAD reached the glibc binary: $out" ;;
esac

case "$out" in
  *"audit=none"*) ok "LD_AUDIT is dropped before exec" ;;
  *) bad "LD_AUDIT reached the glibc binary: $out" ;;
esac

case "$out" in
  *"xdg=none"*) ok "XDG_DATA_HOME from a V2 shell is dropped" ;;
  *) bad "XDG_DATA_HOME survived: $out" ;;
esac

case "$out" in
  *"library-path=$SANDBOX/prefix/glibc/lib"*) ok "the glibc lib dir is passed to the loader" ;;
  *) bad "loader got the wrong library path: $out" ;;
esac

case "$out" in
  *"real args=run --model x"*) ok "arguments are forwarded to the payload" ;;
  *) bad "arguments were not forwarded: $out" ;;
esac

case "$out" in
  *"tls=$SANDBOX/prefix/etc/tls/cert.pem"*) ok "SSL_CERT_FILE points at the Termux bundle" ;;
  *) bad "SSL_CERT_FILE is wrong: $out" ;;
esac

if out="$(run_launcher 7)"; then
  bad "payload exit code 7 was swallowed"
else
  ok "the payload exit code is returned"
fi

printf '\n%s passed · %s failed\n' "$pass" "$fail"
rm -rf "$SANDBOX"
[ "$fail" -eq 0 ]
