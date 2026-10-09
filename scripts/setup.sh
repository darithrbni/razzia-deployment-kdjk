#!/usr/bin/env bash
# Setup Razzia for KDJK 2026/2027 — Kelompok P1 / Kelompok 8.
# Run: sudo bash setup.sh
set -Eeuo pipefail
umask 077

APP_DIR="/opt/razzia"
APP_PORT="3000"
DOMAIN="razzia-kdjk.web.id"
IMAGE="ralex91/razzia:latest"
COMPOSE_RENDERED_TMP=""

log(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
fatal(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup(){
  if [[ -n "$COMPOSE_RENDERED_TMP" && -e "$COMPOSE_RENDERED_TMP" ]]; then
    rm -f -- "$COMPOSE_RENDERED_TMP"
  fi
  if [[ -n "${RAZZIA_MANAGER_PASSWORD+x}" ]]; then unset RAZZIA_MANAGER_PASSWORD; fi
}
trap cleanup EXIT

[[ ${EUID} -eq 0 ]] || fatal 'Jalankan dengan sudo atau sebagai root.'
command -v apt-get >/dev/null 2>&1 || fatal 'Script ini ditujukan untuk Ubuntu/Debian.'
command -v docker >/dev/null 2>&1 || fatal 'Docker belum terpasang. Pasang Docker Engine terlebih dahulu.'
docker info >/dev/null 2>&1 || fatal 'Docker daemon tidak berjalan.'
docker compose version >/dev/null 2>&1 || fatal 'Docker Compose plugin tidak tersedia.'

missing=()
command -v curl >/dev/null 2>&1 || missing+=(curl)
command -v python3 >/dev/null 2>&1 || missing+=(python3)
if ((${#missing[@]})); then
  log "Memasang paket yang diperlukan: ${missing[*]}"
  apt-get update
  apt-get install -y "${missing[@]}"
fi

if [[ -L "$APP_DIR" ]]; then fatal "$APP_DIR tidak boleh berupa symlink."; fi
if [[ -e "$APP_DIR" && ! -d "$APP_DIR" ]]; then fatal "$APP_DIR sudah ada tetapi bukan direktori."; fi
if [[ -L "$APP_DIR/config" ]]; then fatal "$APP_DIR/config tidak boleh berupa symlink."; fi
if [[ -e "$APP_DIR/config" && ! -d "$APP_DIR/config" ]]; then fatal "$APP_DIR/config ada tetapi bukan direktori."; fi
install -d -m 700 "$APP_DIR" "$APP_DIR/config"

if [[ ! -e "$APP_DIR/compose.yml" ]]; then
  cat > "$APP_DIR/compose.yml" <<EOF_COMPOSE
services:
  razzia:
    image: ${IMAGE}
    restart: unless-stopped
    ports:
      - "127.0.0.1:${APP_PORT}:3000"
    volumes:
      - ./config:/app/config
EOF_COMPOSE
  chmod 600 "$APP_DIR/compose.yml"
  log 'compose.yml dibuat.'
else
  [[ -f "$APP_DIR/compose.yml" ]] || fatal 'compose.yml ada tetapi bukan berkas biasa.'
  log 'compose.yml yang sudah ada dipertahankan.'
fi

GAME_CONFIG="$APP_DIR/config/game.json"
if [[ ! -e "$GAME_CONFIG" ]]; then
  log 'Buat password manager yang kuat dan unik.'
  while true; do
    IFS= read -r -s -p 'Password manager: ' MANAGER_PASSWORD || fatal 'Gagal membaca password.'
    printf '\n'
    [[ -n "$MANAGER_PASSWORD" ]] || { warn 'Password tidak boleh kosong.'; continue; }
    [[ "$MANAGER_PASSWORD" != 'PASSWORD' ]] || { warn 'Jangan gunakan password default.'; continue; }
    IFS= read -r -s -p 'Ulangi password: ' PASSWORD_CONFIRM || fatal 'Gagal membaca konfirmasi password.'
    printf '\n'
    if [[ "$MANAGER_PASSWORD" == "$PASSWORD_CONFIRM" ]]; then break; fi
    unset PASSWORD_CONFIRM
    warn 'Password tidak cocok.'
  done
  export RAZZIA_MANAGER_PASSWORD="$MANAGER_PASSWORD"
  unset MANAGER_PASSWORD PASSWORD_CONFIRM
  python3 - "$GAME_CONFIG" <<'PY'
import json, os, sys
path = sys.argv[1]
tmp = path + ".tmp"
try:
    with open(tmp, "x", encoding="utf-8") as f:
        json.dump({"managerPassword": os.environ["RAZZIA_MANAGER_PASSWORD"]}, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
    raise
PY
  unset RAZZIA_MANAGER_PASSWORD
else
  [[ -f "$GAME_CONFIG" && ! -L "$GAME_CONFIG" ]] || fatal 'config/game.json harus berupa berkas biasa, bukan symlink.'
  log 'game.json yang sudah ada dipertahankan.'
fi

[[ -f "$GAME_CONFIG" && ! -L "$GAME_CONFIG" ]] || fatal 'config/game.json tidak valid sebagai berkas biasa.'
chmod 700 "$APP_DIR/config"
chmod 600 "$GAME_CONFIG"
python3 - "$GAME_CONFIG" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        config = json.load(f)
    password = config.get("managerPassword")
    if not isinstance(password, str) or not password.strip() or password == "PASSWORD":
        raise ValueError("managerPassword harus berupa string nonkosong dan bukan password default")
except (OSError, json.JSONDecodeError, ValueError) as exc:
    print(f"[ERROR] Konfigurasi game.json tidak valid: {exc}", file=sys.stderr)
    sys.exit(1)
PY

COMPOSE_RENDERED_TMP="$(mktemp "$APP_DIR/.compose-rendered.XXXXXX.tmp")"
chmod 600 "$COMPOSE_RENDERED_TMP"
log 'Memvalidasi konfigurasi Compose dan pemetaan port...'
docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" config --format json > "$COMPOSE_RENDERED_TMP"
python3 - "$COMPOSE_RENDERED_TMP" "$APP_PORT" <<'PY'
import json, sys
path, expected_port = sys.argv[1], str(sys.argv[2])
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    services = data.get("services", {})
    found = False
    for service, config in services.items():
        for port in config.get("ports", []) or []:
            published = str(port.get("published", ""))
            target = int(port.get("target", 0))
            host_ip = port.get("host_ip")
            if published and host_ip not in ("127.0.0.1", "::1", "localhost"):
                raise ValueError(f"service {service!r} menerbitkan port {published} pada alamat non-loopback ({host_ip!r})")
            if published == expected_port and target == 3000 and host_ip == "127.0.0.1":
                found = True
    if not found:
        raise ValueError(f"harus ada mapping efektif 127.0.0.1:{expected_port}:3000")
except (OSError, json.JSONDecodeError, TypeError, ValueError) as exc:
    print(f"[ERROR] Konfigurasi port tidak aman/tidak valid: {exc}", file=sys.stderr)
    sys.exit(1)
PY
rm -f -- "$COMPOSE_RENDERED_TMP"
COMPOSE_RENDERED_TMP=""

log 'Mengunduh image dan menjalankan Razzia...'
cd "$APP_DIR"
docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" pull
docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" up -d
docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" ps

log 'Menunggu endpoint HTTP lokal...'
healthy=0
for _ in {1..20}; do
  if curl -fsS --max-time 3 "http://127.0.0.1:${APP_PORT}/" >/dev/null 2>&1; then healthy=1; break; fi
  sleep 2
done
if ((healthy == 0)); then
  docker compose -f "$APP_DIR/compose.yml" --project-directory "$APP_DIR" logs --tail=100 || true
  fatal 'Razzia belum merespons. Periksa log sebelum melanjutkan.'
fi

printf '\n[INFO] Instalasi berhasil: endpoint HTTP lokal merespons.\n'
printf '[INFO] URL publik yang diharapkan: https://%s\n' "$DOMAIN"
if command -v caddy >/dev/null 2>&1; then
  log 'Caddy terdeteksi; script ini tidak mengubah konfigurasi Caddy.'
else
  warn 'Caddy tidak terdeteksi. Siapkan reverse proxy HTTPS sebelum memakai domain publik.'
fi
warn 'Pemeriksaan ini hanya menguji HTTP lokal, bukan DNS/HTTPS publik atau izin baca config dari dalam container.'
