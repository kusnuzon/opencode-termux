# opencode-termux

Installer **opencode** (agensi AI coding terminal) untuk **Termux / Android**, satu perintah, dan selalu mengikuti versi resmi opencode yang terbaru.

> Repo resmi `anomalyco/opencode` **tidak punya build `android/arm64`**, dan `npm i -g opencode-ai` **gagal** di Termux.
> Repo ini solve dua masalah itu: memasang binary resmi yang bisa jalan di Android, **dan** memperbaruinya otomatis mengikuti rilisan upstream.

```bash
curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/install.sh | bash
```

Selesai → `opencode` langsung bisa dipakai.

> Kalau mau mengirim opsi lewat pipe, pakai `bash -s -- <opsi>`:
> `curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/install.sh | bash -s -- --upgrade`

---

## Kenapa butuh repo ini?

| Cara | Hasil di Termux |
|---|---|
| `npm i -g opencode-ai` | ❌ Gagal — npm tidak punya binary `android/arm64` |
| Build `musl` (`opencode-linux-arm64-musl.tar.gz`) | ❌ Gagal — bukan fully static (butuh `/lib/ld-musl-aarch64.so.1`), dan Android tidak punya `/etc/resolv.conf` |
| Build `linux-arm64` biasa | ❌ Gagal — butuh loader glibc (`/lib64/ld-linux-aarch64.so.1`), sedangkan Android pakai bionic |
| **Build `linux-arm64` + loader glibc Termux** | ✅ **Ini yang dipakai repo ini** |

Cara kerjanya: binary resmi opencode (glibc) dijalankan melalui **loader glibc dari Termux** (`$PREFIX/glibc/lib/ld-linux-aarch64.so.1`). Jadi yang terpasang di HP tetap **binary resmi opencode**, bukan build modifikasi.

---

## 1. Install (dari nol)

Buka Termux, lalu **satu perintah**:

```bash
curl -fsSL https://raw.githubusercontent.com/kusnuzon/opencode-termux/main/install.sh | bash
```

Yang dikerjakan otomatis:

1. `pkg install curl tar ca-certificates jq`
2. `pkg install glibc-repo` + `glibc` + `termux-exec-glibc` (runtime glibc — wajib)
3. Launcher: pakai paket dpkg `opencode` (repo termuxvoid) **atau** launcher bawaan repo ini, mana yang tersedia
4. `apt-mark hold opencode` → supaya `pkg upgrade` tidak menimpa binary yang baru dipasang
5. Unduh payload versi terbaru → pasang → **verifikasi** `opencode --version`
6. Kalau verifikasi gagal → payload lama otomatis dikembalikan (rollback)

Cek hasilnya:

```bash
opencode --version     # contoh: 1.19.3
opencode               # mulai sesi
```

> Butuh ±500 MB (runtime glibc) + ±180 MB (payload opencode).

---

## 2. Upgrade ke versi terbaru

```bash
bash install.sh --upgrade     # atau: bash upgrade.sh
bash install.sh --check       # cek status saja, tidak mengubah apa pun
```

Script menanyakan GitHub API `anomalyco/opencode/releases/latest`, lalu:

- kalau versi sudah sama → **tidak melakukan apa-apa** (aman dijalankan berkala)
- kalau ada yang lebih baru → unduh → **backup versi lama** ke `~/backups/` → ganti payload → verifikasi → **rollback otomatis** bila gagal
- bisa dipasang versi tertentu: `bash install.sh --version 1.19.3`

### Update otomatis tanpa manual

Repo ini punya GitHub Actions (`sync-upstream.yml`) yang **setiap hari** (±03:17 UTC) mengecek rilisan upstream lalu:

1. mengunduh `opencode-linux-arm64.tar.gz` versi terbaru
2. memperbarui file `VERSION`
3. menerbitkan **Release mirror** `opencode-termux-<versi>` (berisi payload + launcher)

Jadi `install.sh` selalu punya sumber unduhan yang sinkron dengan upstream, dan `install.sh` sendiri sudah otomatis ambil versi terbaru setiap kali dijalankan.

---

## 3. Uninstall

```bash
bash uninstall.sh            # hapus payload + launcher
bash uninstall.sh --purge    # sekalian lepas paket dpkg opencode + runtime glibc
```

Config dan riwayat sesi (`~/.config/opencode`, `~/.local/share/opencode`) **tidak** dihapus.

---

## 4. Manual (kalau mau tanpa script)

```bash
# 1. runtime glibc
pkg install glibc-repo
pkg update && pkg install glibc termux-exec-glibc

# 2. payload resmi
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

# 4. cek
opencode --version
```

---

## 5. Troubleshooting

| Gejala | Penyebab | Solusi |
|---|---|---|
| `cannot execute: required file not found` | Payload tanpa loader glibc | `pkg install glibc termux-exec-glibc`, lalu `bash install.sh --upgrade` |
| `bash: opencode: command not found` | Launcher hilang | `curl -fsSL .../opencode-launcher \| sed "s\|@PREFIX@\|$PREFIX\|g" > $PREFIX/bin/opencode` |
| Versi lama muncul lagi setelah `pkg upgrade` | Paket dpkg menimpa payload | `bash install.sh --upgrade` (repo ini sudah `apt-mark hold`) |
| Error TLS / `unable to verify` | `SSL_CERT_FILE` tidak set | Launcher sudah men-set `SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem`; pastikan `ca-certificates` terpasang |
| DNS gagal | Android tidak punya `/etc/resolv.conf` | Runtime glibc Termux sudah menangani ini; **jangan** pakai build musl |
| `pkg install opencode` versi lama | Repo termuxvoid lambat update | `bash install.sh --upgrade` (payload diambil dari release resmi, bukan dari dpkg) |

---

## 6. Isi repo

| File | Fungsi |
|---|---|
| `install.sh` | Installer utama: deps → glibc runtime → launcher → payload terbaru → verifikasi |
| `upgrade.sh` | Alias `install.sh --upgrade` |
| `uninstall.sh` | Hapus opencode (opsional `--purge` untuk paket glibc juga) |
| `opencode-launcher` | Launcher: menjalankan binary glibc lewat loader glibc Termux |
| `VERSION` | Versi opencode yang sedang dimirror (diperbarui otomatis oleh Actions) |
| `.github/workflows/sync-upstream.yml` | Cron harian: cek upstream → mirror → terbitkan Release |

---

## 7. Catatan & lisensi

- **Bukan afiliasi resmi** opencode. Yang dimirror hanya payload binary dari GitHub Release `anomalyco/opencode`.
- Semua installer/launcher di repo ini: **MIT License**.
- Kalau ada versi opencode yang lebih baru, `install.sh` akan mengikutinya otomatis — tidak perlu update manual.
