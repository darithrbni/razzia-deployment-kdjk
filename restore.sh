#!/usr/bin/env bash
# Restore compose.yml dan config/ dari arsip backup.sh.
# Run: sudo bash restore.sh /path/to/razzia-backup.tar.gz
set -Eeuo pipefail
umask 077

APP_DIR="/opt/razzia"
BACKUP_DIR="/opt/razzia-backups"
APP_PORT=3000
WORK_DIR=""
STAGE_DIR=""
ROLLBACK_DIR=""
SAFETY_BACKUP=""
log(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
fatal(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup(){ [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"; }
trap cleanup EXIT

[[ ${EUID} -eq 0 ]] || fatal 'Jalankan dengan sudo atau sebagai root.'
[[ $# -eq 1 ]] || fatal "Pemakaian: sudo bash $0 /path/ke/backup.tar.gz"
for cmd in python3 docker curl tar realpath; do command -v "$cmd" >/dev/null 2>&1 || fatal "Perintah wajib tidak ditemukan: $cmd"; done
BACKUP_FILE="$(realpath -e -- "$1")" || fatal 'Path backup tidak dapat ditemukan.'
[[ -f "$BACKUP_FILE" && ! -L "$BACKUP_FILE" ]] || fatal 'Path backup harus berupa berkas biasa, bukan symlink.'
docker info >/dev/null 2>&1 || fatal 'Docker daemon tidak berjalan.'
docker compose version >/dev/null 2>&1 || fatal 'Docker Compose tidak tersedia.'
[[ -f "$APP_DIR/compose.yml" && ! -L "$APP_DIR/compose.yml" && -d "$APP_DIR/config" && ! -L "$APP_DIR/config" && -f "$APP_DIR/config/game.json" && ! -L "$APP_DIR/config/game.json" ]] || fatal "Deployment aktif tidak lengkap di $APP_DIR."
install -d -m 700 "$BACKUP_DIR"
WORK_DIR="$(mktemp -d "$BACKUP_DIR/.restore-work-XXXXXX")"
STAGE_DIR="$WORK_DIR/staged"
ROLLBACK_DIR="$WORK_DIR/rollback"
mkdir -m 700 "$STAGE_DIR" "$ROLLBACK_DIR"

log 'Memvalidasi arsip dan mengekstrak ke staging...'
python3 - "$BACKUP_FILE" "$STAGE_DIR" <<'PY'
import os, sys, tarfile
from pathlib import PurePosixPath
src, dest = sys.argv[1:3]
try:
    with tarfile.open(src, "r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise ValueError("arsip kosong")
        seen = set()
        total_size = 0
        if len(members) > 10000:
            raise ValueError("jumlah entri arsip melebihi batas 10000")
        for member in members:
            raw = member.name
            if not raw or raw.startswith("/") or "\\" in raw:
                raise ValueError(f"path absolut/kosong/tidak valid: {raw!r}")
            path = PurePosixPath(raw)
            if ".." in path.parts or "." in path.parts:
                raise ValueError(f"path tidak aman: {raw!r}")
            name = str(path).rstrip("/")
            if name in seen:
                raise ValueError(f"entri duplikat: {name!r}")
            seen.add(name)
            if name not in ("compose.yml", "config") and not name.startswith("config/"):
                raise ValueError(f"entri tidak diharapkan: {name!r}")
            if not (member.isfile() or member.isdir()):
                raise ValueError(f"tautan/berkas khusus tidak diizinkan: {name!r}")
            if member.isfile():
                total_size += member.size
                if total_size > 512 * 1024 * 1024:
                    raise ValueError("ukuran isi arsip melebihi batas 512 MiB")
        if not {"compose.yml", "config", "config/game.json"}.issubset(seen):
            raise ValueError("arsip harus berisi compose.yml, config/, dan config/game.json")
        for member in members:
            rel = PurePosixPath(member.name)
            target = os.path.join(dest, *rel.parts)
            if member.isdir():
                os.makedirs(target, mode=0o700, exist_ok=True)
            else:
                os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
                source = archive.extractfile(member)
                if source is None:
                    raise ValueError(f"gagal membaca {member.name}")
                with source, open(target, "xb") as out:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        out.write(chunk)
                os.chmod(target, 0o600)
except (OSError, tarfile.TarError, ValueError) as exc:
    print(f"[ERROR] Backup tidak valid: {exc}", file=sys.stderr)
    sys.exit(1)
PY

python3 - "$STAGE_DIR/config/game.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        config = json.load(f)
    password = config.get("managerPassword")
    if not isinstance(password, str) or not password.strip() or password == "PASSWORD":
        raise ValueError("managerPassword tidak valid")
except (OSError, json.JSONDecodeError, ValueError) as exc:
    print(f"[ERROR] game.json dalam backup tidak valid: {exc}", file=sys.stderr)
    sys.exit(1)
PY

docker compose -f "$STAGE_DIR/compose.yml" --project-directory "$APP_DIR" config --quiet || fatal 'compose.yml dalam backup tidak valid.'
printf '\n'
warn 'Restore mengganti compose.yml dan seluruh direktori config/.'
warn 'Image Docker, konfigurasi Caddy, dan sertifikat TLS tidak dipulihkan.'
read -r -p 'Ketik YES untuk melanjutkan: ' answer
[[ "$answer" == YES ]] || { log 'Restore dibatalkan; deployment tidak diubah.'; exit 0; }

SAFETY_TMP="$(mktemp "$BACKUP_DIR/.pre-restore-XXXXXX.tmp")"
if ! tar -czf "$SAFETY_TMP" -C "$APP_DIR" compose.yml config; then
  rm -f -- "$SAFETY_TMP"
  fatal 'Gagal membuat safety backup; deployment tidak diubah.'
fi
if ! python3 - "$SAFETY_TMP" <<'PY'
import sys, tarfile
try:
    with tarfile.open(sys.argv[1], "r:gz") as archive:
        members = archive.getmembers()
        names = {m.name.rstrip("/") for m in members}
        if not {"compose.yml", "config", "config/game.json"}.issubset(names):
            raise ValueError("arsip keselamatan tidak lengkap")
        if any(not (m.isfile() or m.isdir()) for m in members):
            raise ValueError("arsip keselamatan mengandung tautan/berkas khusus")
except (OSError, tarfile.TarError, ValueError) as exc:
    print(f"[ERROR] Safety backup gagal: {exc}", file=sys.stderr)
    sys.exit(1)
PY
then
  rm -f -- "$SAFETY_TMP"
  fatal 'Safety backup tidak lolos verifikasi; deployment tidak diubah.'
fi
SAFETY_BACKUP="$BACKUP_DIR/pre-restore-$(date +'%Y-%m-%d_%H-%M-%S')-$$.tar.gz"
mv -- "$SAFETY_TMP" "$SAFETY_BACKUP"
chmod 600 "$SAFETY_BACKUP"
cp -a "$APP_DIR/compose.yml" "$ROLLBACK_DIR/compose.yml"
cp -a "$APP_DIR/config" "$ROLLBACK_DIR/config"

wait_healthy(){
  local attempt
  for attempt in {1..20}; do
    if curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}
rollback(){
  warn 'Restore gagal; mengembalikan konfigurasi lama...'
  local rollback_failed=0
  # Restore the previous files first. Do not let failure to stop the new project
  # prevent attempts to start the previous configuration.
  if ! cp -a "$ROLLBACK_DIR/compose.yml" "$APP_DIR/compose.yml"; then
    warn 'Gagal menyalin kembali compose.yml lama.'
    rollback_failed=1
  fi
  if ! rm -rf -- "$APP_DIR/config"; then
    warn 'Gagal menghapus config hasil restore.'
    rollback_failed=1
  elif ! cp -a "$ROLLBACK_DIR/config" "$APP_DIR/config"; then
    warn 'Gagal menyalin kembali config lama.'
    rollback_failed=1
  fi
  if (( rollback_failed == 0 )); then
    if ! docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" config --quiet; then
      warn 'Konfigurasi lama tidak lolos validasi Compose.'
      rollback_failed=1
    elif ! docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" up -d --force-recreate; then
      warn 'Tidak berhasil menjalankan kembali konfigurasi lama.'
      rollback_failed=1
    elif ! wait_healthy; then
      warn 'Konfigurasi lama diterapkan tetapi endpoint HTTP tidak merespons.'
      rollback_failed=1
    fi
  fi
  if (( rollback_failed == 0 )); then
    warn 'Rollback terverifikasi: konfigurasi lama dipulihkan dan HTTP lokal merespons.'
    return 0
  fi
  warn "Rollback tidak terverifikasi. Periksa log dan safety backup: $SAFETY_BACKUP"
  docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" logs --tail=100 || true
  return 1
}

log 'Menghentikan deployment sebelum mengganti file...'
if ! docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" down; then
  fatal 'Tidak dapat menghentikan deployment; restore dibatalkan tanpa mengganti file aktif.'
fi
if ! cp -a "$STAGE_DIR/compose.yml" "$APP_DIR/compose.yml" || ! { rm -rf -- "$APP_DIR/config" && cp -a "$STAGE_DIR/config" "$APP_DIR/config"; }; then
  rollback || true
  fatal "Gagal menyalin file restore. Safety backup: $SAFETY_BACKUP"
fi
if ! docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" config --quiet; then
  rollback || true
  fatal "Konfigurasi hasil restore tidak valid. Safety backup: $SAFETY_BACKUP"
fi
if ! docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" up -d; then
  rollback || true
  fatal "Container gagal dijalankan setelah restore. Safety backup: $SAFETY_BACKUP"
fi
if ! wait_healthy; then
  docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" logs --tail=100 || true
  rollback || true
  fatal "Pemeriksaan HTTP gagal setelah restore. Safety backup: $SAFETY_BACKUP"
fi
log 'Restore berhasil dan endpoint HTTP lokal merespons.'
log "Safety backup konfigurasi sebelumnya: $SAFETY_BACKUP"
warn 'Pemeriksaan ini hanya menguji HTTP lokal, bukan HTTPS publik.'
