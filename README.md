# opencode-termux

Installer for **opencode** (the terminal AI coding agent) on **Termux / Android**: one command, and it always tracks the latest official opencode release.

> The official `anomalyco/opencode` repo has **no `android/arm64` build**, and `npm i -g opencode-ai` **fails** on Termux.
> This repo solves both problems: it installs the official binary in a form that runs on Android, **and** keeps it updated from upstream releases.

```bash
curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/install.sh | bash
```

Done — `opencode` is ready to use.

> To pass options through a pipe, use `bash -s -- <options>`:
> `curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/install.sh | bash -s -- --upgrade`

---

## Why this repo exists

| Approach | Result on Termux |
|---|---|
| `npm i -g opencode-ai` | ❌ Fails — npm has no `android/arm64` binary |
| `musl` build (`opencode-linux-arm64-musl.tar.gz`) | ❌ Fails — not fully static (needs `/lib/ld-musl-aarch64.so.1`), and Android has no `/etc/resolv.conf` |
| Plain `linux-arm64` build | ❌ Fails — needs a glibc loader (`/lib64/ld-linux-aarch64.so.1`), while Android uses bionic |
| **`linux-arm64` build + Termux glibc loader** | ✅ **What this repo uses** |

How it works: the official opencode binary (glibc) is executed through **Termux's glibc loader** (`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`). So what ends up on your phone is still the **official opencode binary**, not a patched build.

---

## 1. Install (from scratch)

Open Termux and run **one command**:

```bash
curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/install.sh | bash
```

What it does automatically:

1. Installs base dependencies **first** (a fresh Termux is usable right away):
   `curl tar unzip gzip coreutils ca-certificates jq python git sqlite wget
   openssh gh nodejs yq shellcheck ncdu htop`, then optionally `tesseract
   chromium` (+ `x11-repo`). Optional failures only produce a warning;
   skip them with `--no-extra`.
2. `pkg install glibc-repo` + `glibc` + `termux-exec-glibc` (glibc runtime — required).
   If the glibc packages break `curl` (`cannot locate symbol SSL_set_quic_…`),
   `curl`/`libcurl`/`openssl` are reinstalled automatically and downloads have
   `wget`/`python` fallbacks.
3. Launcher: it uses the dpkg `opencode` package (termuxvoid repo) **or** the launcher bundled with this repo, whichever is available
4. `apt-mark hold opencode` → so `pkg upgrade` cannot overwrite the binary that was just installed
5. Downloads the latest payload → installs it → **verifies** `opencode --version`
6. If verification fails → the previous payload is restored automatically (rollback)
7. Installs the `memory.js` + `session-title.js` plugins, then the memory templates
   (`MEMORY.md`, `AGENTS.md`, `RECENT.md`) and the `~/.bashrc` hook — **existing
   files are never overwritten**. Skip with `--no-plugin` / `--no-memory`.

Check the result:

```bash
opencode --version     # example: 1.19.3
opencode               # start a session
```

> Needs about 500 MB (glibc runtime) + about 180 MB (opencode payload).

### Cross-session memory (default)

With no extra options, the installer already sets up:

| File | Contents |
|---|---|
| `plugins/memory.js` → `~/.config/opencode/plugins/` | `memory_save` tool (V1 + V2) |
| `plugins/session-title.js` → `~/.config/opencode/plugins/` | automatic session titles without calling a model |
| `memory/MEMORY.md` → `~/.config/opencode/MEMORY.md` | empty template, filled in through `memory_save` |
| `memory/AGENTS.md` → `~/.config/opencode/AGENTS.md` | working-rules template |
| `memory/opencode.jsonc` → `~/.config/opencode/opencode.jsonc` | `instructions`: MEMORY.md + RECENT.md |
| `plugins/session-digest.py` → `~/.config/opencode/bin/` | builds `RECENT.md` from the V1 + V2 databases |

`MEMORY.md` holds long-term facts and `RECENT.md` summarizes recent sessions;
both are loaded automatically at the start of a new session. Existing data is
never lost — the installer skips memory files that already exist. To skip the
setup: `--no-memory` (templates) or `--no-plugin` (plugins).

---

## 2. Upgrade to the latest version

```bash
bash install.sh --upgrade     # or: bash upgrade.sh
bash install.sh --check       # status only, changes nothing
```

The script asks the GitHub API for `anomalyco/opencode/releases/latest`, then:

- if the versions match → **does nothing** (safe to run on a schedule)
- if a newer one exists → download → **back up the old version** to `~/backups/` → swap the payload → verify → **automatic rollback** on failure
- you can install a specific version: `bash install.sh --version 1.19.3`

### Automatic updates without manual work

This repo ships a GitHub Actions workflow (`sync-upstream.yml`) that **every day** (around 03:17 UTC) checks upstream releases and then:

1. downloads the latest `opencode-linux-arm64.tar.gz`
2. updates the `VERSION` file
3. publishes a **mirror Release** `opencode-termux-<version>` (payload + launcher)

So `install.sh` always has a download source that is in sync with upstream, and `install.sh` itself always picks up the latest version whenever it runs.

---

## 3. Uninstall

```bash
bash uninstall.sh            # remove payload + launcher
bash uninstall.sh --purge    # also remove the opencode dpkg package + glibc runtime
```

Config and session history (`~/.config/opencode`, `~/.local/share/opencode`) are **not** removed.

---

## 4. Manual (if you prefer no script)

```bash
# 1. glibc runtime
pkg install glibc-repo
pkg update && pkg install glibc termux-exec-glibc

# 2. official payload
mkdir -p $PREFIX/share/opencode
curl -fL -o opencode.tar.gz \
  https://github.com/anomalyco/opencode/releases/download/v1.19.3/opencode-linux-arm64.tar.gz
tar -xzf opencode.tar.gz -C $PREFIX/share/opencode
mv $PREFIX/share/opencode/opencode $PREFIX/share/opencode/opencode.real
chmod 755 $PREFIX/share/opencode/opencode.real

# 3. launcher
curl -fsSL -o $PREFIX/bin/opencode \
  https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/opencode-launcher
sed -i "s|@PREFIX@|$PREFIX|g" $PREFIX/bin/opencode
chmod 755 $PREFIX/bin/opencode

# 4. check
opencode --version
```

---

## 5. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `cannot execute: required file not found` | Payload without a glibc loader | `pkg install glibc termux-exec-glibc`, then `bash install.sh --upgrade` |
| `bash: opencode: command not found` | Launcher missing | `curl -fsSL .../opencode-launcher \| sed "s\|@PREFIX@\|$PREFIX\|g" > $PREFIX/bin/opencode` |
| An old version reappears after `pkg upgrade` | The dpkg package overwrote the payload | `bash install.sh --upgrade` (this repo already runs `apt-mark hold`) |
| TLS error / `unable to verify` | `SSL_CERT_FILE` not set | The launcher already sets `SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem`; make sure `ca-certificates` is installed |
| DNS fails | Android has no `/etc/resolv.conf` | The Termux glibc runtime already handles this; do **not** use the musl build |
| `pkg install opencode` gives an old version | The termuxvoid repo updates slowly | `bash install.sh --upgrade` (the payload comes from the official release, not from dpkg) |

---

## 6. Repo contents

| File | Purpose |
|---|---|
| `install.sh` | Main installer: deps → glibc runtime → launcher → latest payload → verification → plugins/memory |
| `plugins/` | `memory.js`, `session-title.js`, `session-digest.py` |
| `memory/` | Templates for `MEMORY.md`, `AGENTS.md`, `opencode.jsonc` |
| `upgrade.sh` | Alias for `install.sh --upgrade` |
| `uninstall.sh` | Removes opencode (add `--purge` to drop the glibc packages too) |
| `opencode-launcher` | Launcher: runs the glibc binary through the Termux glibc loader |
| `VERSION` | The opencode version currently mirrored (updated automatically by Actions) |
| `.github/workflows/sync-upstream.yml` | Daily cron: check upstream → mirror → publish a Release |

---

## 7. Notes & license

- **Not officially affiliated** with opencode. Only the binary payload from the `anomalyco/opencode` GitHub Releases is mirrored.
- Every installer/launcher in this repo is under the **MIT License**.
- When a newer opencode release appears, `install.sh` follows it automatically — no manual update needed.
