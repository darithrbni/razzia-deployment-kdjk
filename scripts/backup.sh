#!/usr/bin/env bash
# Backup compose.yml dan config/ Razzia; tidak mencadangkan image Docker atau Caddy.
# Run: sudo bash backup.sh
set -Eeuo pipefail
umask 077

APP_DIR="/opt/razzia"
BACKUP_DIR="/opt/razzia-backups"
STAMP="$(date +'%Y-%m-%d_%H-%M-%S')"
BACKUP_FILE="$BACKUP_DIR/razzia-backup-${STAMP}-$$.tar.gz"
TEMP_FILE=""
log(){ printf '[INFO] %s\n' "$*"; }
fatal(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup(){ [[ -z "$TEMP_FILE" || ! -e "$TEMP_FILE" ]] || rm -f -- "$TEMP_FILE"; }
trap cleanup EXIT

[[ ${EUID} -eq 0 ]] || fatal 'Jalankan dengan sudo atau sebagai root.'
for cmd in docker python3 tar; do command -v "$cmd" >/dev/null 2>&1 || fatal "Perintah wajib tidak ditemukan: $cmd"; done
docker info >/dev/null 2>&1 || fatal 'Docker daemon tidak berjalan.'
docker compose version >/dev/null 2>&1 || fatal 'Docker Compose tidak tersedia.'
[[ -d "$APP_DIR" && -f "$APP_DIR/compose.yml" && ! -L "$APP_DIR/compose.yml" && -d "$APP_DIR/config" && ! -L "$APP_DIR/config" && -f "$APP_DIR/config/game.json" && ! -L "$APP_DIR/config/game.json" ]] || fatal "Deployment tidak lengkap atau menggunakan symlink pada path utama di $APP_DIR."

python3 - "$APP_DIR/config/game.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        config = json.load(f)
    password = config.get("managerPassword")
    if not isinstance(password, str) or not password.strip():
        raise ValueError("managerPassword kosong atau tidak ada")
except (OSError, json.JSONDecodeError, ValueError) as exc:
    print(f"[ERROR] game.json tidak valid: {exc}", file=sys.stderr)
    sys.exit(1)
PY

docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" config --quiet || fatal 'Konfigurasi Compose tidak valid.'
install -d -m 700 "$BACKUP_DIR"
TEMP_FILE="$(mktemp "$BACKUP_DIR/.razzia-backup-XXXXXX.tmp")"
chmod 600 "$TEMP_FILE"
log 'Membuat arsip konfigurasi...'
tar -czf "$TEMP_FILE" -C "$APP_DIR" compose.yml config
python3 - "$TEMP_FILE" <<'PY'
import sys, tarfile
try:
    with tarfile.open(sys.argv[1], "r:gz") as archive:
        members = archive.getmembers()
        names = set()
        for member in members:
            name = member.name.rstrip("/")
            if not name or name.startswith("/") or ".." in name.split("/"):
                raise ValueError("jalur arsip tidak aman")
            if not (member.isfile() or member.isdir()):
                raise ValueError(f"tautan/berkas khusus tidak diizinkan: {name}")
            names.add(name)
        if not {"compose.yml", "config", "config/game.json"}.issubset(names):
            raise ValueError("compose.yml, config/, atau config/game.json tidak ada dalam arsip")
except (OSError, tarfile.TarError, ValueError) as exc:
    print(f"[ERROR] Verifikasi arsip gagal: {exc}", file=sys.stderr)
    sys.exit(1)
PY
chmod 600 "$TEMP_FILE"
mv -- "$TEMP_FILE" "$BACKUP_FILE"
TEMP_FILE=""
printf '\n[INFO] Backup berhasil dibuat: %s\n' "$BACKUP_FILE"
printf '[INFO] Ukuran: %s\n' "$(du -h "$BACKUP_FILE" | cut -f1)"
cat <<'EOF_INFO'
[INFO] Isi backup: compose.yml dan config/.
[WARN] Backup TIDAK mencakup image Docker, konfigurasi Caddy, sertifikat TLS, atau data di luar config/.
[WARN] Salin backup ke luar VPS. Jangan unggah arsip yang berisi password ke repositori publik.
[WARN] Jalankan backup ketika konfigurasi tidak sedang diedit agar hasilnya konsisten.
EOF_INFO
