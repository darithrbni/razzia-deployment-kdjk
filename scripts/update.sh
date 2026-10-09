#!/usr/bin/env bash
# Update Razzia with a config backup and verified best-effort rollback to saved local image.
# Run: sudo bash update.sh
set -Eeuo pipefail
umask 077

APP_DIR="/opt/razzia"
BACKUP_DIR="/opt/razzia-backups"
APP_PORT=3000
STAMP="$(date +'%Y-%m-%d_%H-%M-%S')"
BACKUP_FILE="$BACKUP_DIR/pre-update-${STAMP}-$$.tar.gz"
ROLLBACK_OVERRIDE="$BACKUP_DIR/pre-update-${STAMP}-$$.rollback.json"
TEMP_FILE=""
IMAGE_STATE_FILE=""
log(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
fatal(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup(){
  [[ -z "$TEMP_FILE" || ! -e "$TEMP_FILE" ]] || rm -f -- "$TEMP_FILE"
  [[ -z "$IMAGE_STATE_FILE" || ! -e "$IMAGE_STATE_FILE" ]] || rm -f -- "$IMAGE_STATE_FILE"
}
trap cleanup EXIT

[[ ${EUID} -eq 0 ]] || fatal 'Jalankan dengan sudo atau sebagai root.'
for cmd in docker curl tar python3; do command -v "$cmd" >/dev/null 2>&1 || fatal "Perintah wajib tidak ditemukan: $cmd"; done
docker info >/dev/null 2>&1 || fatal 'Docker daemon tidak berjalan.'
docker compose version >/dev/null 2>&1 || fatal 'Docker Compose tidak tersedia.'
[[ -f "$APP_DIR/compose.yml" && ! -L "$APP_DIR/compose.yml" && -d "$APP_DIR/config" && ! -L "$APP_DIR/config" && -f "$APP_DIR/config/game.json" && ! -L "$APP_DIR/config/game.json" ]] || fatal "Deployment tidak lengkap atau menggunakan symlink pada path utama di $APP_DIR."
docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" config --quiet || fatal 'Konfigurasi Compose tidak valid.'
python3 - "$APP_DIR/config/game.json" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        config = json.load(f)
    password = config.get("managerPassword")
    if not isinstance(password, str) or not password.strip() or password == "PASSWORD":
        raise ValueError("managerPassword kosong/tidak valid")
except (OSError, json.JSONDecodeError, ValueError) as exc:
    print(f"[ERROR] game.json tidak valid: {exc}", file=sys.stderr)
    sys.exit(1)
PY

install -d -m 700 "$BACKUP_DIR"
TEMP_FILE="$(mktemp "$BACKUP_DIR/.pre-update-XXXXXX.tmp")"
chmod 600 "$TEMP_FILE"
log 'Membuat backup konfigurasi sebelum update...'
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
                raise ValueError("path arsip tidak aman")
            if not (member.isfile() or member.isdir()):
                raise ValueError("tautan/berkas khusus tidak diizinkan")
            names.add(name)
        if not {"compose.yml", "config", "config/game.json"}.issubset(names):
            raise ValueError("isi backup tidak lengkap")
except (OSError, tarfile.TarError, ValueError) as exc:
    print(f"[ERROR] Verifikasi backup gagal: {exc}", file=sys.stderr)
    sys.exit(1)
PY
mv -- "$TEMP_FILE" "$BACKUP_FILE"
TEMP_FILE=""
chmod 600 "$BACKUP_FILE"

# This update helper intentionally supports the project's single-service Compose
# deployment only. Fail closed rather than perform a partial rollback on a larger stack.
RENDERED="$(docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" config --format json)"
SERVICE_INFO="$(python3 -c 'import json,sys; d=json.load(sys.stdin); s=d.get("services",{}); print(len(s)); print(next(iter(s), "")); print(next(iter(s.values()), {}).get("image", ""))' <<< "$RENDERED")"
SERVICE_COUNT="$(printf '%s\n' "$SERVICE_INFO" | sed -n '1p')"
SERVICE_NAME="$(printf '%s\n' "$SERVICE_INFO" | sed -n '2p')"
IMAGE_REF="$(printf '%s\n' "$SERVICE_INFO" | sed -n '3p')"
[[ "$SERVICE_COUNT" == 1 && -n "$SERVICE_NAME" && -n "$IMAGE_REF" ]] || fatal "Script update ini hanya mendukung tepat satu service Compose yang memakai image; backup: $BACKUP_FILE"
CONTAINER_IDS="$(docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" ps -q "$SERVICE_NAME")"
[[ -n "$CONTAINER_IDS" ]] || fatal "Container service '$SERVICE_NAME' tidak ditemukan; tidak aman melakukan update. Backup konfigurasi: $BACKUP_FILE"
[[ "$(printf '%s\n' "$CONTAINER_IDS" | wc -l | tr -d ' ')" == 1 ]] || fatal "Service '$SERVICE_NAME' memiliki lebih dari satu container; rollback otomatis tidak didukung. Backup konfigurasi: $BACKUP_FILE"
CONTAINER_ID="$(printf '%s\n' "$CONTAINER_IDS" | sed -n '1p')"
OLD_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$CONTAINER_ID")"
[[ "$OLD_IMAGE_ID" == sha256:* ]] || fatal 'Tidak dapat menentukan image ID lama.'
docker image inspect "$OLD_IMAGE_ID" >/dev/null 2>&1 || fatal 'Image lama tidak tersedia secara lokal; rollback tidak dapat disiapkan.'

ROLLBACK_TAG="local/razzia-rollback:${STAMP}-$$"
docker image tag "$OLD_IMAGE_ID" "$ROLLBACK_TAG"
ROLLBACK_OVERRIDE_TMP="$(mktemp "$BACKUP_DIR/.rollback-override-XXXXXX.tmp")"
chmod 600 "$ROLLBACK_OVERRIDE_TMP"
python3 - "$SERVICE_NAME" "$ROLLBACK_TAG" "$ROLLBACK_OVERRIDE_TMP" <<'PY'
import json, sys
service, image, path = sys.argv[1:]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"services": {service: {"image": image}}}, f, indent=2)
    f.write("\n")
PY
mv -- "$ROLLBACK_OVERRIDE_TMP" "$ROLLBACK_OVERRIDE"
chmod 600 "$ROLLBACK_OVERRIDE"

printf '\n'
warn "Service yang akan diperbarui: $SERVICE_NAME"
warn "Image saat ini: $OLD_IMAGE_ID"
warn "Backup konfigurasi: $BACKUP_FILE"
warn 'Rollback image lokal disiapkan sebelum update; tag rollback akan dipertahankan setelah script selesai.'
read -r -p 'Ketik YES untuk melanjutkan update: ' answer
[[ "$answer" == YES ]] || { log "Update dibatalkan. Backup: $BACKUP_FILE; override rollback: $ROLLBACK_OVERRIDE"; exit 0; }

wait_healthy(){
  local attempt
  for attempt in {1..20}; do
    if curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}
rollback_image(){
  warn 'Mencoba menjalankan image lokal yang disimpan sebelum update...'
  if docker compose -f "$APP_DIR/compose.yml" -f "$ROLLBACK_OVERRIDE" --project-directory "$APP_DIR" up -d --force-recreate "$SERVICE_NAME" && wait_healthy; then
    warn 'Rollback terverifikasi: endpoint HTTP lokal kembali merespons dengan override image lama.'
    return 0
  fi
  warn 'Rollback image tidak terverifikasi. Periksa status container dan log.'
  docker compose -f "$APP_DIR/compose.yml" -f "$ROLLBACK_OVERRIDE" --project-directory "$APP_DIR" logs --tail=100 || true
  return 1
}

log 'Mengunduh image yang dikonfigurasi...'
if ! docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" pull; then
  fatal "Pull image gagal. Script belum menjalankan recreate. Backup: $BACKUP_FILE"
fi
log 'Menerapkan update...'
if ! docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" up -d; then
  rollback_image || warn 'Rollback gagal/tidak terverifikasi; intervensi manual diperlukan.'
  fatal "Update gagal. Backup konfigurasi: $BACKUP_FILE; override rollback: $ROLLBACK_OVERRIDE"
fi
if ! wait_healthy; then
  docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" logs --tail=100 || true
  rollback_image || warn 'Rollback gagal/tidak terverifikasi; intervensi manual diperlukan.'
  fatal "Update tidak lolos pemeriksaan HTTP. Backup konfigurasi: $BACKUP_FILE; override rollback: $ROLLBACK_OVERRIDE"
fi

docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" ps
log 'Update berhasil; endpoint HTTP lokal merespons.'
log "Backup konfigurasi: $BACKUP_FILE"
log "Override rollback image lama: $ROLLBACK_OVERRIDE"
warn 'Rollback hanya mencakup image service tunggal yang dicatat. HTTP lokal tidak membuktikan DNS/HTTPS publik sehat.'
