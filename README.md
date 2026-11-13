# 🚀 OpenCode V1 for Termux (Android arm64)

Installs the **official opencode binary** on Termux with **one command** — and
keeps following upstream releases, so you never install it by hand again.

> ⚠️ `npm i -g opencode-ai` fails on Termux (no `android/arm64` build) and the
> official repo has no Android binary. This repo runs the official glibc binary
> through Termux's glibc loader — nothing is recompiled or patched.

## ❓ Why this repo exists

| Approach | Result on Termux |
|---|---|
| `npm i -g opencode-ai` | ❌ no `android/arm64` package |
| musl build | ❌ not fully static, no `/etc/resolv.conf` on Android |
| plain `linux-arm64` build | ❌ needs `/lib64/ld-linux-aarch64.so.1` (Android uses bionic) |
| **`linux-arm64` + Termux glibc loader** | ✅ **what this repo does** |

## 📦 Prerequisites

Termux on Android **aarch64**, not root, ~700 MB free (glibc runtime + payload).
Dependencies are installed by the script.

## ⚡ 1-Click Install

```bash
curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/install.sh | bash
```

Pass options through the pipe with `bash -s --`:

```bash
… | bash -s -- --upgrade       # upgrade to the latest release
… | bash -s -- --check         # status only, changes nothing
… | bash -s -- --version 1.19.5  # pin a specific version
```

Check the result:

```bash
opencode --version
opencode
```

## 🧰 What the installer does

1. 📦 base dependencies first (`curl tar unzip gzip coreutils ca-certificates jq
   python git sqlite wget openssh gh nodejs yq shellcheck ncdu htop`), optionally
   `tesseract chromium` — optional failures only warn (`--no-extra` to skip)
2. 🧬 glibc runtime (`glibc-repo`, `glibc`, `termux-exec-glibc`); if the glibc
   packages break `curl`, it is reinstalled automatically
3. 🚀 launcher into `$PREFIX/bin/opencode`
4. 🔒 `apt-mark hold opencode` so `pkg upgrade` cannot overwrite the payload
5. ⬇️ latest official payload → verify `opencode --version`
6. ↩️ on failure the previous payload is restored automatically
7. 🧠 plugins + memory templates (`--no-plugin` / `--no-memory` to skip)

## 🧠 Cross-session memory (default)

| File | Contents |
|---|---|
| `plugins/memory.js` | `memory_save` tool (V1 + V2) |
| `plugins/session-title.js` | session titles without calling a model |
| `memory/MEMORY.md` | long-term facts (template, filled by the tool) |
| `memory/AGENTS.md` | working-rules template |
| `memory/opencode.jsonc` | `instructions`: MEMORY.md + RECENT.md |
| `plugins/session-digest.py` | builds `RECENT.md` (recent sessions + open items) |
| `plugins/update-notice.js` | shows a codemux update notice inside the session |
| `plugins/kuota.py` → `kuota` | estimates the remaining free-model quota |

`MEMORY.md` + `RECENT.md` are loaded automatically in every new session.
Existing files are **never overwritten**.

## ⬆️ Upgrade

```bash
bash install.sh --upgrade     # or: bash upgrade.sh
bash install.sh --check       # status only
```

Version matches upstream → does nothing. Newer version → back up the old payload
to `~/backups/`, swap, verify, rollback on failure.

## 🤖 Automatic mirror

A GitHub Actions workflow (`sync-upstream.yml`) runs daily (~03:17 UTC): checks
`anomalyco/opencode/releases/latest`, updates `VERSION`, and publishes the mirror
release `opencode-termux-<version>`. So the installer always has a fresh source.

## 🛠️ Manual install (no script)

```bash
pkg install glibc-repo
pkg update && pkg install glibc termux-exec-glibc

mkdir -p $PREFIX/share/opencode
curl -fL -o opencode.tar.gz \
  https://github.com/anomalyco/opencode/releases/download/v1.19.5/opencode-linux-arm64.tar.gz
tar -xzf opencode.tar.gz -C $PREFIX/share/opencode
mv $PREFIX/share/opencode/opencode $PREFIX/share/opencode/opencode.real
chmod 755 $PREFIX/share/opencode/opencode.real

curl -fsSL -o $PREFIX/bin/opencode \
  https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/opencode-launcher
sed -i "s|@PREFIX@|$PREFIX|g" $PREFIX/bin/opencode
chmod 755 $PREFIX/bin/opencode
opencode --version
```

## 🩺 Troubleshooting

| Symptom | Fix |
|---|---|
| `cannot execute: required file not found` | `pkg install glibc termux-exec-glibc`, then `install.sh --upgrade` |
| `bash: opencode: command not found` | reinstall the launcher with `install.sh --upgrade` |
| old version comes back after `pkg upgrade` | `install.sh --upgrade` (hold is already set) |
| TLS error / `unable to verify` | install `ca-certificates`; the launcher sets `SSL_CERT_FILE` |
| DNS fails | do **not** use the musl build — the Termux glibc runtime handles this |
| `pkg install opencode` gives an old build | `install.sh --upgrade` (payload comes from the official release) |

## 🗑️ Uninstall

```bash
bash uninstall.sh            # remove payload + launcher
bash uninstall.sh --purge    # also remove the opencode package + glibc runtime
```

Sessions and config (`~/.config/opencode`, `~/.local/share/opencode`) stay.

## 📁 Repo contents

```
install.sh          deps → glibc → launcher → payload → verify → plugins
upgrade.sh          alias for install.sh --upgrade
uninstall.sh        remove the payload (--purge drops glibc too)
opencode-launcher   runs the glibc binary through the Termux loader
plugins/            memory.js, session-title.js, update-notice.js,
                    session-digest.py, kuota.py
memory/             MEMORY.md, AGENTS.md, opencode.jsonc templates
VERSION             mirrored opencode version (updated by Actions)
```

## ⚠️ Notes

- **Not officially affiliated** with opencode; only the official binary payload
  is mirrored.
- V1 and V2 can coexist — use [opencode-termux-v2](https://github.com/kusnuzon/opencode-termux-v2)
  for the 2.x line, or [codemux](https://github.com/kusnuzon/codemux) to manage both.

## 📜 License

[MIT](LICENSE)
