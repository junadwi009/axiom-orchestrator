#!/usr/bin/env bash
# =============================================================================
# setup_local.sh
# One-shot bootstrap untuk Ubuntu 24.04 LTS (lokal dev maupun VPS Contabo).
# =============================================================================
# Yang dilakukan script:
#   1. Cek prereq: docker, docker-compose-plugin, git, openssl
#   2. Generate semua password & API hash (kalau belum ada)
#   3. Build .env dari .env.example dengan password yang di-generate
#   4. Generate userlist.txt PgBouncer
#   5. Inisialisasi git submodule crypto-bot
#   6. docker compose up -d (kecuali profile 'production')
#   7. Healthcheck loop sampai semua service ready
#   8. Print credentials summary ke ./credentials.txt (chmod 600)
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# --- Color helpers --------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${BLUE}[setup]${NC} $*"; }
ok()    { echo -e "${GREEN}[ ✓  ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# --- 1) Prereq check ------------------------------------------------------
log "Step 1/8: cek prerequisite tools..."

command -v docker >/dev/null 2>&1 || fail "Docker tidak terinstall. Install: https://docs.docker.com/engine/install/ubuntu/"
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin tidak ada. Install: sudo apt-get install docker-compose-plugin"
command -v git >/dev/null 2>&1 || fail "git tidak ada. Install: sudo apt-get install git"
command -v openssl >/dev/null 2>&1 || fail "openssl tidak ada. Install: sudo apt-get install openssl"
command -v python3 >/dev/null 2>&1 || warn "python3 tidak ada — disarankan untuk validasi script."

# Cek user dalam docker group
if ! groups | grep -q docker; then
    warn "User '$USER' belum masuk grup docker. Run: sudo usermod -aG docker \$USER && relogin."
fi

ok "Semua tools tersedia."

# --- 2) Generate passwords ------------------------------------------------
log "Step 2/8: generate password (skip kalau .env sudah ada)..."

ENV_FILE="$ROOT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
    warn ".env sudah ada — skip generate. Hapus manual kalau mau regenerate."
else
    [[ -f "$ROOT_DIR/.env.example" ]] || fail ".env.example tidak ditemukan."

    cp "$ROOT_DIR/.env.example" "$ENV_FILE"

    # Generator: 32-char alphanumeric password
    gen_pw() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32; }

    PW_AXIOM=$(gen_pw)
    PW_CRYPTO=$(gen_pw)
    PW_OBSERVER=$(gen_pw)
    PW_PARAM=$(gen_pw)
    PW_N8N_DB=$(gen_pw)
    PW_PGB_ADMIN=$(gen_pw)
    PW_REDIS=$(gen_pw)
    PW_N8N_BASIC=$(gen_pw)

    # Replace placeholders in .env
    sed -i "s|REPLACE_AXIOM_DB_PW|$PW_AXIOM|g" "$ENV_FILE"
    sed -i "s|REPLACE_CRYPTOBOT_DB_PW|$PW_CRYPTO|g" "$ENV_FILE"
    sed -i "s|REPLACE_OBSERVER_DB_PW|$PW_OBSERVER|g" "$ENV_FILE"
    sed -i "s|REPLACE_PARAMSYNC_DB_PW|$PW_PARAM|g" "$ENV_FILE"
    sed -i "s|REPLACE_N8N_DB_PW|$PW_N8N_DB|g" "$ENV_FILE"
    sed -i "s|REPLACE_PGB_ADMIN_PW|$PW_PGB_ADMIN|g" "$ENV_FILE"
    sed -i "s|REPLACE_REDIS_PW|$PW_REDIS|g" "$ENV_FILE"
    sed -i "s|REPLACE_N8N_BASIC_PW|$PW_N8N_BASIC|g" "$ENV_FILE"

    chmod 600 "$ENV_FILE"
    ok "Generated 8 passwords. Tersimpan ke .env (chmod 600)."

    # Save plaintext credentials.txt untuk Aru — JANGAN COMMIT
    cat > "$ROOT_DIR/credentials.txt" <<EOF
# =============================================================================
# credentials.txt — generated $(date -u +%FT%TZ)
# JANGAN COMMIT FILE INI. Tambahkan ke .gitignore.
# Password berikut sudah ter-inject ke .env. Simpan untuk recovery.
# =============================================================================
DB_PASSWORD_AXIOM=$PW_AXIOM
DB_PASSWORD_CRYPTOBOT=$PW_CRYPTO
DB_PASSWORD_OBSERVER=$PW_OBSERVER
DB_PASSWORD_PARAMSYNC=$PW_PARAM
DB_PASSWORD_N8N=$PW_N8N_DB
PGB_ADMIN_PASSWORD=$PW_PGB_ADMIN
REDIS_PASSWORD=$PW_REDIS
N8N_BASIC_AUTH_PASSWORD=$PW_N8N_BASIC

# WAJIB di-set MANUAL di .env (script tidak generate ini):
#   OPENROUTER_API_KEY=
#   ANTHROPIC_API_KEY=
#   BYBIT_API_KEY=
#   BYBIT_API_SECRET=
#   TELEGRAM_BOT_TOKEN_AXIOM=
#   TELEGRAM_BOT_TOKEN_CRYPTOBOT=
#   TELEGRAM_CHAT_ID=
#   BOT_PIN_HASH=        # bcrypt hash, generate via Python: bcrypt.hashpw(b"yourpin", bcrypt.gensalt())
EOF
    chmod 600 "$ROOT_DIR/credentials.txt"
fi

# --- 3) Generate PgBouncer userlist.txt -----------------------------------
log "Step 3/8: generate pgbouncer/userlist.txt..."

USERLIST="$ROOT_DIR/pgbouncer/userlist.txt"
[[ -d "$ROOT_DIR/pgbouncer" ]] || fail "Folder pgbouncer/ tidak ada. Cek struktur project."

if [[ -f "$USERLIST" ]] && [[ -s "$USERLIST" ]]; then
    warn "userlist.txt sudah ada — skip."
else
    # Source .env untuk ambil password
    set -a; source "$ENV_FILE"; set +a

    # PgBouncer md5 hash format: md5( md5(password+username) )
    md5h() {
        local user="$1" pw="$2"
        echo -n "${pw}${user}" | md5sum | awk '{print "md5"$1}'
    }

    cat > "$USERLIST" <<EOF
"axiom_user"          "$(md5h axiom_user "$DB_PASSWORD_AXIOM")"
"cryptobot_user"      "$(md5h cryptobot_user "$DB_PASSWORD_CRYPTOBOT")"
"readonly_observer"   "$(md5h readonly_observer "$DB_PASSWORD_OBSERVER")"
"parameter_sync_user" "$(md5h parameter_sync_user "$DB_PASSWORD_PARAMSYNC")"
"n8n_user"            "$(md5h n8n_user "$DB_PASSWORD_N8N")"
"pgbouncer_admin"     "$(md5h pgbouncer_admin "$PGB_ADMIN_PASSWORD")"
EOF

    chmod 600 "$USERLIST"
    ok "userlist.txt generated."
fi

# --- 4) Init crypto-bot submodule -----------------------------------------
log "Step 4/8: init git submodule crypto-bot..."

if [[ -d "$ROOT_DIR/agents/crypto_bot/.git" ]] || [[ -f "$ROOT_DIR/agents/crypto_bot/.git" ]]; then
    ok "Submodule sudah ada — fetch update..."
    git -C "$ROOT_DIR" submodule update --init --recursive
    git -C "$ROOT_DIR/agents/crypto_bot" pull origin main || warn "git pull gagal — cek konektivitas."
else
    if grep -q 'agents/crypto_bot' "$ROOT_DIR/.gitmodules" 2>/dev/null; then
        git -C "$ROOT_DIR" submodule update --init --recursive
    else
        # Hapus stub lama kalau ada (bot.py executioner stub yg dihapus per Konflik 1)
        if [[ -d "$ROOT_DIR/agents/crypto_bot" ]] && [[ ! -d "$ROOT_DIR/agents/crypto_bot/.git" ]]; then
            warn "Folder agents/crypto_bot/ ada tapi bukan git repo — backup ke agents/crypto_bot.bak/"
            mv "$ROOT_DIR/agents/crypto_bot" "$ROOT_DIR/agents/crypto_bot.bak.$(date +%s)"
        fi

        log "Adding submodule https://github.com/junadwi009/crypto-bot.git ..."
        git -C "$ROOT_DIR" submodule add https://github.com/junadwi009/crypto-bot.git agents/crypto_bot
        git -C "$ROOT_DIR" submodule update --init --recursive
    fi
    ok "Submodule terinisialisasi di agents/crypto_bot/."
fi

# --- 5) Validate config files ---------------------------------------------
log "Step 5/8: validasi config files..."

[[ -f "$ROOT_DIR/docker-compose.yaml" ]] || fail "docker-compose.yaml tidak ada."
[[ -f "$ROOT_DIR/init.sql" ]] || fail "init.sql tidak ada."
[[ -f "$ROOT_DIR/init_cryptobot_db.sql" ]] || fail "init_cryptobot_db.sql tidak ada."

docker compose config --quiet || fail "docker-compose.yaml invalid."
ok "Semua config valid."

# --- 6) Build & start containers ------------------------------------------
log "Step 6/8: docker compose up -d (skip profile production)..."

docker compose up -d --build

ok "Containers spawning..."

# --- 7) Healthcheck loop --------------------------------------------------
log "Step 7/8: tunggu service ready (max 120 detik)..."

REQUIRED_SERVICES=(axiom_db axiom_redis axiom_pgbouncer axiom_brain cryptobot_main)
TIMEOUT=120
ELAPSED=0

while (( ELAPSED < TIMEOUT )); do
    ALL_OK=true
    for svc in "${REQUIRED_SERVICES[@]}"; do
        STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "no-healthcheck")
        if [[ "$STATUS" != "healthy" ]] && [[ "$STATUS" != "no-healthcheck" ]]; then
            ALL_OK=false
            break
        fi
    done
    if $ALL_OK; then break; fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -n "."
done
echo ""

if $ALL_OK; then
    ok "Semua service core healthy dalam ${ELAPSED}s."
else
    warn "Timeout ${TIMEOUT}s. Cek: docker compose ps && docker compose logs <service>"
fi

# --- 8) Summary -----------------------------------------------------------
log "Step 8/8: summary"

cat <<'EOF'

==============================================================================
  AXIOM + CRYPTO-BOT LOCAL STACK READY
==============================================================================

  Container status:    docker compose ps
  Logs (semua):        docker compose logs -f
  Logs (1 service):    docker compose logs -f axiom_brain
  Stop all:            docker compose down
  Reset (NUKE data):   docker compose down -v

  n8n dashboard:       http://localhost:5678
  Crypto-bot API:      http://localhost:8000
  PgBouncer port:      6432  (pakai untuk connect dari host: psql -h localhost -p 6432 -U axiom_user axiom_memories)

  Credentials:         ./credentials.txt  (chmod 600)
  Env file:            ./.env             (chmod 600)

  WAJIB DIISI MANUAL DI .env SEBELUM PRODUCTION:
    - OPENROUTER_API_KEY
    - ANTHROPIC_API_KEY
    - BYBIT_API_KEY / BYBIT_API_SECRET
    - TELEGRAM_BOT_TOKEN_AXIOM
    - TELEGRAM_BOT_TOKEN_CRYPTOBOT
    - TELEGRAM_CHAT_ID
    - BOT_PIN_HASH

  Next: baca CLAUDE_INSTRUCTIONS.md, lalu DEVELOPMENT_ROADMAP.md untuk Phase berikutnya.
==============================================================================
EOF
