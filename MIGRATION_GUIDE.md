# MIGRATION_GUIDE.md — RENDER → VPS CONTABO

> **Status:** AUTHORITATIVE | **Owner:** Aru (aru009)
> File ini definisikan **prosedur migrasi step-by-step** dari deployment lama (Render + Supabase) ke VPS Contabo + self-hosted Postgres.
> **Wajib** baca sebelum touch VPS production.

→ Prerequisite: **[CLAUDE_INSTRUCTIONS.md](./CLAUDE_INSTRUCTIONS.md)**, **[ARCHITECTURE.md](./ARCHITECTURE.md)**, **[DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md)**, **[DEVELOPMENT_ROADMAP.md](./DEVELOPMENT_ROADMAP.md#phase-2--migration-render--vps-contabo)** sudah dibaca.

---

## 1. INVENTARIS DEPLOYMENT LAMA

### 1.1 Render Services (existing)

Berdasarkan `agents/crypto_bot/render.yaml`:

| Service | Type | Plan | Region | Notes |
|---|---|---|---|---|
| `cryptobot-prod` | worker | starter | singapore | Python 3.11.9, run `python main.py` |

### 1.2 Environment Variables di Render

Wajib di-export sebelum migrasi (dari Render dashboard atau CLI):

| Variable | Sumber | Status pasca-migrasi |
|---|---|---|
| `BYBIT_API_KEY` | Bybit dashboard | Pindahkan ke `.env` di VPS |
| `BYBIT_API_SECRET` | Bybit dashboard | Pindahkan ke `.env` di VPS |
| `BYBIT_TESTNET` | env | Pindahkan, default `false` di production |
| `ANTHROPIC_API_KEY` | Anthropic console | Pindahkan ke `.env` di VPS |
| `ANTHROPIC_SPENDING_LIMIT` | env | Pindahkan, default `30` |
| `SUPABASE_URL` | Supabase dashboard | **DEPRECATED** post-migrasi (gunakan local Postgres) |
| `SUPABASE_SERVICE_KEY` | Supabase dashboard | **DEPRECATED** post-migrasi |
| `TELEGRAM_BOT_TOKEN` | BotFather | **RENAME** ke `TELEGRAM_BOT_TOKEN_CRYPTOBOT` |
| `TELEGRAM_CHAT_ID` | env | Tetap |
| `BOT_PIN_HASH` | generate | Tetap |
| `PAPER_TRADE` | env | Tetap |
| `INITIAL_CAPITAL` | env | Default `213` |
| `RENDER_BILLING_DAY` | env | **DEPRECATED** post-migrasi |
| `BOT_TIMEZONE` | env | Tetap (`Asia/Jakarta`) |
| `REDIS_URL` | Render Redis (jika ada) | **DEPRECATED**, ganti ke local Redis |
| `FRONTEND_URL` | env | Update ke domain VPS post-migrasi |

### 1.3 Supabase Database (existing)

| Database | Tabel | Estimasi rows |
|---|---|---|
| Default Supabase Postgres | 12 tabel sesuai `agents/crypto_bot/database/schema.sql` | tergantung lama running, mungkin ribuan-jutaan trades + bot_events |

---

## 2. STRATEGI MIGRASI: ZERO-DOWNTIME (atau Minimum Downtime)

Ada 2 pilihan strategi:

### Strategi A: Hot Cutover (downtime <30 menit)
Cocok jika Render bot saat ini dalam paper mode (no real positions di Bybit).

```
T-24h:  Provision VPS, install dependencies, build images
T-12h:  Setup VPS infrastruktur (Docker, networks, volumes)
T-6h:   Setup database lokal di VPS, jalankan init.sql
T-2h:   Pre-migration backup Supabase (full pg_dump)
T-1h:   Render bot di-set ke maintenance mode (manual stop trading)
T=0:    Cutover:
        1. Stop Render bot
        2. Final pg_dump Supabase
        3. Apply data ke VPS Postgres
        4. Update DNS / IP whitelist Bybit ke VPS IP
        5. Start crypto-bot di VPS
        6. Verify trading loop running
T+30m:  Validation: trade loop normal, telegram respond
T+24h:  Monitor untuk anomali
T+72h:  Suspend Render service (jangan delete dulu — backup)
T+30d:  Delete Render service
```

### Strategi B: Parallel Run (downtime 0, butuh care)
Cocok jika sudah live trading (ada open positions). Lebih kompleks tapi safer.

```
T-7d:   Provision VPS, deploy dengan PAPER_TRADE=true
T-3d:   Sync database dari Supabase ke VPS via logical replication (CDC)
T-1d:   Switch crypto-bot di VPS ke read-only mode terhadap Bybit (no new orders)
T=0:    Cutover:
        1. Render bot stop accepting new signals
        2. Final sync DB delta
        3. Switch IP whitelist Bybit ke VPS
        4. VPS bot mulai accept signals
        5. Render bot stop entirely
T+24h:  Monitor parallel observability dengan VPS leading
```

**Rekomendasi**: Pakai **Strategi A** karena bot kemungkinan masih paper-trade dan belum ada open positions yang krusial. Lebih sederhana dan risiko data loss minimal.

---

## 3. DATABASE MIGRATION (Supabase → Local Postgres+Timescale)

### 3.1 Pre-Migration Backup (Critical!)

Lakukan dari laptop Aru, **sebelum** migrasi mulai:

```bash
# Di laptop Aru
mkdir -p ~/cryptobot-pre-migration-backup-$(date +%Y%m%d)
cd ~/cryptobot-pre-migration-backup-$(date +%Y%m%d)

# Get Supabase connection string dari dashboard (Settings > Database > Connection string)
# Format: postgresql://postgres.{project_ref}:{password}@aws-0-{region}.pooler.supabase.com:5432/postgres

export SUPABASE_DSN="postgresql://postgres.xxx:xxx@aws-0-xxx.pooler.supabase.com:5432/postgres"

# Dump schema only
pg_dump --schema-only --no-owner --no-acl -f schema.sql "$SUPABASE_DSN"

# Dump data only (column-inserts untuk safe re-import)
pg_dump --data-only --no-owner --column-inserts -f data.sql "$SUPABASE_DSN"

# Compress
gzip schema.sql data.sql

# Verify file sizes (sanity check)
ls -lh
```

### 3.2 Apply Schema ke VPS Postgres

```bash
# Di VPS (assumed Docker stack sudah UP via docker compose up -d axiom_db)
# Connect ke axiom_db dan create database cryptobot_db
docker exec axiom_db psql -U aru_admin -c "CREATE DATABASE cryptobot_db;"

# Apply baseline schema dari init_cryptobot_db.sql (sudah include hypertable conversions)
docker exec -i axiom_db psql -U aru_admin -d cryptobot_db < /root/axiom_core/init_cryptobot_db.sql

# Verify hypertables
docker exec axiom_db psql -U aru_admin -d cryptobot_db -c \
  "SELECT hypertable_name FROM timescaledb_information.hypertables;"
```

Output expected:
```
 hypertable_name
-----------------
 trades
 bot_events
 news_items
 claude_usage
```

### 3.3 Load Data dari Supabase Dump

```bash
# Upload dump file dari laptop ke VPS via scp
scp ~/cryptobot-pre-migration-backup-{date}/data.sql.gz root@{vps_ip}:/tmp/

# Di VPS
gunzip /tmp/data.sql.gz
docker cp /tmp/data.sql axiom_db:/tmp/data.sql
docker exec axiom_db psql -U aru_admin -d cryptobot_db -f /tmp/data.sql
```

⚠️ **PENTING**: Karena hypertable di-convert via `migrate_data => TRUE`, Supabase data dump akan otomatis ter-distribusi ke chunks. Tidak butuh manual partition.

### 3.4 Validate Migration

```bash
# Hitung rows di local
docker exec axiom_db psql -U aru_admin -d cryptobot_db -c \
"SELECT 'trades' AS t, count(*) FROM trades
 UNION ALL SELECT 'bot_events', count(*) FROM bot_events
 UNION ALL SELECT 'news_items', count(*) FROM news_items
 UNION ALL SELECT 'opus_memory', count(*) FROM opus_memory
 UNION ALL SELECT 'pair_config', count(*) FROM pair_config
 UNION ALL SELECT 'strategy_params', count(*) FROM strategy_params;"

# Bandingkan dengan Supabase (dari laptop)
psql "$SUPABASE_DSN" -c \
"SELECT 'trades' AS t, count(*) FROM trades
 UNION ALL SELECT 'bot_events', count(*) FROM bot_events
 UNION ALL SELECT 'news_items', count(*) FROM news_items
 UNION ALL SELECT 'opus_memory', count(*) FROM opus_memory
 UNION ALL SELECT 'pair_config', count(*) FROM pair_config
 UNION ALL SELECT 'strategy_params', count(*) FROM strategy_params;"
```

Hasil **harus identik**. Jika tidak, jangan lanjut — investigate.

### 3.5 Apply Migration: Add Axiom Triggers ke cryptobot_db

```bash
# Apply migration ke add LISTEN/NOTIFY triggers
docker exec -i axiom_db psql -U aru_admin -d cryptobot_db < /root/axiom_core/migrations/001_axiom_observability.sql
```

→ Migration content: lihat **[INTEGRATION_GUIDE.md](./INTEGRATION_GUIDE.md#next-action)** section "Tambahkan trigger SQL".

---

## 4. CODE MIGRATION: supabase-py → asyncpg

### 4.1 Lokasi File yang Berubah

File-file di crypto-bot repo yang **wajib** di-modify (PR ke `git@github.com:junadwi009/crypto-bot.git`):

1. `requirements.txt` — remove `supabase`, add `asyncpg>=0.29`
2. `database/client.py` — full rewrite
3. `config/settings.py` — replace `SUPABASE_URL`/`SUPABASE_SERVICE_KEY` dengan `DB_HOST`/`DB_PORT`/`DB_USER_CRYPTOBOT`/`DB_PASSWORD_CRYPTOBOT`/`DB_NAME_CRYPTOBOT`

### 4.2 `database/client.py` — Before & After

**BEFORE** (supabase-py):
```python
from supabase import create_client, Client
from config.settings import settings

class DatabaseClient:
    def __init__(self):
        self._client: Client = create_client(
            settings.SUPABASE_URL,
            settings.SUPABASE_SERVICE_KEY
        )
    
    async def get_open_trades(self):
        return self._client.table("trades").select("*").eq("status", "open").execute().data
    
    async def insert_trade(self, trade_data: dict):
        return self._client.table("trades").insert(trade_data).execute()
```

**AFTER** (asyncpg):
```python
import asyncpg
from config.settings import settings

class DatabaseClient:
    _pool: asyncpg.Pool | None = None
    
    @classmethod
    async def init_pool(cls):
        cls._pool = await asyncpg.create_pool(
            host=settings.DB_HOST,
            port=settings.DB_PORT,
            user=settings.DB_USER_CRYPTOBOT,
            password=settings.DB_PASSWORD_CRYPTOBOT,
            database=settings.DB_NAME_CRYPTOBOT,
            min_size=2,
            max_size=10,
            command_timeout=30
        )
    
    async def get_open_trades(self):
        async with self._pool.acquire() as conn:
            rows = await conn.fetch(
                "SELECT * FROM trades WHERE status = $1 ORDER BY opened_at DESC",
                "open"
            )
            return [dict(r) for r in rows]
    
    async def insert_trade(self, trade_data: dict):
        async with self._pool.acquire() as conn:
            return await conn.fetchrow(
                """
                INSERT INTO trades (pair, side, amount_usd, entry_price, status, trigger_source, is_paper)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
                RETURNING id
                """,
                trade_data["pair"],
                trade_data["side"],
                trade_data["amount_usd"],
                trade_data["entry_price"],
                trade_data.get("status", "open"),
                trade_data.get("trigger_source"),
                trade_data.get("is_paper", True)
            )
```

### 4.3 Pattern Translation Reference

| Supabase Operation | asyncpg Equivalent |
|---|---|
| `.table("X").select("*")` | `await conn.fetch("SELECT * FROM X")` |
| `.eq("col", val)` | `WHERE col = $1` parameter |
| `.in_("col", list)` | `WHERE col = ANY($1::text[])` |
| `.lte("col", val)` | `WHERE col <= $1` |
| `.order("col", desc=True)` | `ORDER BY col DESC` |
| `.limit(N)` | `LIMIT $N` |
| `.insert({...})` | `INSERT INTO X (...) VALUES ($1, ...)` |
| `.update({"col": val}).eq("id", X)` | `UPDATE X SET col = $1 WHERE id = $2` |
| `.delete().eq("id", X)` | `DELETE FROM X WHERE id = $1` |
| `.rpc("function_name", {...})` | `await conn.execute("SELECT function_name($1)")` atau call directly |

### 4.4 Test Asyncpg Port di Local Sebelum Deploy ke VPS

⚠️ **JANGAN** push ke main crypto-bot repo sebelum tested. Workflow yang aman:

1. Branch baru di crypto-bot repo: `git checkout -b feature/asyncpg-migration`
2. Implement perubahan
3. Run unit tests: `pytest agents/crypto_bot/tests/test_database.py`
4. Run integration test: connect ke local Postgres, jalankan trading loop di paper mode 1 jam
5. Verify trades tertulis ke DB benar
6. PR ke main, review, merge
7. Update submodule pointer di axiom-orchestrator: `cd agents/crypto_bot && git pull && cd ../.. && git add agents/crypto_bot && git commit -m "[infra] update cryptobot submodule to asyncpg"`

---

## 5. VPS INFRASTRUCTURE SETUP DETAIL

### 5.1 VPS Provisioning Checklist (Contabo)

- [ ] Login ke https://contabo.com
- [ ] Pilih: **Cloud VPS 30 NVMe** (rekomendasi)
  - 4 vCPU
  - 12 GB RAM
  - 200 GB NVMe SSD
  - 32 TB traffic
- [ ] Region: **Singapore** atau **Asia (Tokyo)** — terdekat dari Indonesia untuk latency
- [ ] OS: **Ubuntu 24.04 LTS**
- [ ] Set password awal di console (atau upload SSH public key)
- [ ] Enable IPv6 (optional, untuk future-proof)
- [ ] Setup billing dengan kartu valid
- [ ] Tunggu provisioning (5-15 menit), catat IP public

### 5.2 Initial Hardening

```bash
# SSH ke VPS sebagai root
ssh root@{vps_ip}

# Update sistem
apt update && apt upgrade -y

# Install essential tools
apt install -y curl git ufw fail2ban nano htop ca-certificates lsb-release

# === User non-root setup ===
adduser aru009  # set password kuat
usermod -aG sudo aru009

# === SSH key setup ===
mkdir -p /home/aru009/.ssh
# Append public key dari laptop Aru
echo "ssh-ed25519 AAA... aru@laptop" > /home/aru009/.ssh/authorized_keys
chown -R aru009:aru009 /home/aru009/.ssh
chmod 700 /home/aru009/.ssh
chmod 600 /home/aru009/.ssh/authorized_keys

# === Disable password login & root login ===
sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh

# === Firewall ===
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 5678/tcp comment 'n8n - TODO restrict'  # TODO: restrict ke IP rumah Aru saja
ufw enable
ufw status verbose

# === fail2ban ===
systemctl enable --now fail2ban
```

### 5.3 Install Docker

```bash
# Official install script
curl -fsSL https://get.docker.com | sh

# Plugin docker compose
apt install -y docker-compose-plugin

# Add aru009 ke docker group
usermod -aG docker aru009

# Verify
docker --version
docker compose version

# Start docker on boot
systemctl enable docker
```

### 5.4 Setup Repo Path

```bash
# Sebagai root (atau aru009 dengan sudo)
mkdir -p /root/axiom_core
cd /root/axiom_core

# Clone axiom-orchestrator
git clone <axiom-repo-url> .

# Initialize submodule (crypto-bot dari junadwi009)
git submodule update --init --recursive

# Verify
ls agents/crypto_bot/main.py  # harus exist
```

### 5.5 Generate Production Secrets

```bash
# Generate password kuat untuk DB users
echo "DB_PASSWORD_AXIOM=$(openssl rand -base64 32)"
echo "DB_PASSWORD_CRYPTOBOT=$(openssl rand -base64 32)"
echo "DB_PASSWORD_OBSERVER=$(openssl rand -base64 32)"
echo "DB_PASSWORD_PARAMSYNC=$(openssl rand -base64 32)"
echo "DB_PASSWORD_N8N=$(openssl rand -base64 32)"
echo "REDIS_PASSWORD=$(openssl rand -base64 32)"
echo "N8N_PASSWORD=$(openssl rand -base64 32)"

# Catat output ini di password manager Aru — pakai untuk isi .env
```

### 5.6 Configure .env (Production)

```bash
cd /root/axiom_core
cp .env.example .env
nano .env

# Isi semua field termasuk passwords yang baru di-generate
# Pastikan PAPER_TRADE=true untuk warm-up phase
# Pastikan BYBIT_TESTNET=false jika sudah punya akun mainnet (testnet jika belum)

# Lock permissions
chmod 600 .env
chown root:root .env
```

---

## 6. DOCKER STACK STARTUP

### 6.1 Pre-flight Checks

```bash
cd /root/axiom_core

# Verify all required files exist
ls docker-compose.yaml init.sql init_cryptobot_db.sql .env

# Verify submodule
git submodule status  # harus tampil commit hash, no '-' prefix

# Check disk space
df -h /root  # minimum 50 GB free

# Check memory
free -h  # minimum 10 GB available
```

### 6.2 Build Images

```bash
docker compose build

# Lihat output, pastikan no errors
# Image yang harus ter-build:
# - axiom_brain (Dockerfile.brain)
# - axiom_bridge (Dockerfile.bridge)
# - axiom_thanatos (Dockerfile.thanatos)
# - axiom_telegram (Dockerfile.telegram)
# - axiom_pattern (Dockerfile.pattern, NEW)
# - axiom_consensus (Dockerfile.consensus, NEW)
# - cryptobot_main (build context = ./agents/crypto_bot/)
# - cryptobot_param_sync (image sama dengan cryptobot_main, command berbeda)
```

### 6.3 First Start (Database & Redis Only)

```bash
# Start core infra dulu
docker compose up -d axiom_db axiom_redis axiom_pgbouncer

# Tunggu Postgres ready
sleep 30
docker exec axiom_db pg_isready -U aru_admin

# Verify init.sql sudah jalan
docker exec axiom_db psql -U aru_admin -d axiom_memories -c "\dt"
docker exec axiom_db psql -U aru_admin -d axiom_memories -c \
  "SELECT extname FROM pg_extension WHERE extname='timescaledb';"

# Apply migrasi data Supabase (lihat section 3.3)
# ...

# Verify Redis
docker exec axiom_redis redis-cli -a "$REDIS_PASSWORD" ping  # PONG
```

### 6.4 Start Full Stack

```bash
docker compose up -d

# Verify all containers
docker compose ps

# Expected output: 11 containers, all "Up" status

# Watch logs untuk error:
docker compose logs -f --tail=100
```

### 6.5 Healthcheck Validation

```bash
# Crypto-bot health
curl -i http://localhost:8000/health

# n8n health
curl -i http://localhost:5678/healthz

# Container healthcheck status
docker inspect cryptobot_main --format='{{.State.Health.Status}}'
docker inspect axiom_db --format='{{.State.Health.Status}}'
```

---

## 7. NGINX REVERSE PROXY + LET'S ENCRYPT (Frontend Deployment)

### 7.1 Install Nginx & Certbot

```bash
apt install -y nginx certbot python3-certbot-nginx
systemctl enable --now nginx
```

### 7.2 DNS Setup

Di registrar Aru:
- A record: `your-domain.com` → `{vps_ip}`
- A record: `www.your-domain.com` → `{vps_ip}` (optional)
- TTL: 60 detik untuk migrasi (ubah ke 3600 setelah stable)

### 7.3 Build Frontend

```bash
# Install Node.js 20
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

# Build frontend
cd /root/axiom_core/agents/crypto_bot/frontend
npm install
npm run build

# Copy ke serve folder
mkdir -p /var/www/cryptobot
cp -r dist/* /var/www/cryptobot/
chown -R www-data:www-data /var/www/cryptobot
```

### 7.4 Nginx Config

```bash
nano /etc/nginx/sites-available/cryptobot
```

Isi:
```nginx
server {
    listen 80;
    server_name your-domain.com www.your-domain.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name your-domain.com www.your-domain.com;

    # SSL akan diisi otomatis oleh certbot
    
    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    
    # Static frontend
    root /var/www/cryptobot;
    index index.html;
    
    location / {
        try_files $uri $uri/ /index.html;
        # CSP, X-Frame-Options, etc
        add_header X-Frame-Options "SAMEORIGIN";
        add_header X-Content-Type-Options "nosniff";
    }
    
    # API reverse proxy ke crypto-bot FastAPI
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        proxy_pass http://localhost:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }
    
    # Healthcheck (no rate limit)
    location /api/health {
        proxy_pass http://localhost:8000/health;
    }
    
    # Larangan akses .env, .git, dll
    location ~ /\.(env|git) {
        deny all;
        return 404;
    }
}
```

```bash
ln -s /etc/nginx/sites-available/cryptobot /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx
```

### 7.5 Get TLS Cert via Certbot

```bash
certbot --nginx -d your-domain.com -d www.your-domain.com \
  --non-interactive --agree-tos --email aru009@example.com

# Auto-renewal (cron sudah otomatis di-setup oleh certbot)
certbot renew --dry-run
```

### 7.6 Frontend Validation

```bash
# Dari laptop Aru
curl -I https://your-domain.com  # 200 OK
curl https://your-domain.com/api/health  # bot health JSON
```

Buka `https://your-domain.com` di browser → frontend dashboard load.

---

## 8. SUBMODULE REPLACEMENT (Detail)

Per Konflik 8 = "Ganti ke submodule".

### 8.1 Jika Sudah Ada Folder `agents/crypto_bot/` (Stub)

```bash
cd /root/axiom_core

# Hapus folder lama (yang berisi stub bot.py & Dockerfile.bot)
rm -rf agents/crypto_bot
git rm -rf agents/crypto_bot

# Add sebagai submodule
git submodule add git@github.com:junadwi009/crypto-bot.git agents/crypto_bot

# Commit
git commit -m "[infra] convert agents/crypto_bot to git submodule"
git push
```

### 8.2 Update docker-compose.yaml

`Dockerfile.bot` lama (stub) sudah tidak relevan. Service `cryptobot_main` build dari context `agents/crypto_bot/Dockerfile`:

```yaml
cryptobot_main:
  build:
    context: ./agents/crypto_bot
    dockerfile: Dockerfile  # crypto-bot punya Dockerfile sendiri
  container_name: cryptobot_main
  restart: unless-stopped
  env_file:
    - .env
  environment:
    - DB_HOST=axiom_pgbouncer
    - DB_PORT=6432
    - DB_NAME=cryptobot_db
    - DB_USER=cryptobot_user
    - DB_PASSWORD=${DB_PASSWORD_CRYPTOBOT}
    - REDIS_URL=redis://:${REDIS_PASSWORD}@axiom_redis:6379
    - TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN_CRYPTOBOT}
  ports:
    - "8000:8000"
  depends_on:
    axiom_db: { condition: service_healthy }
    axiom_redis: { condition: service_healthy }
    axiom_pgbouncer: { condition: service_started }
  networks:
    - axiom-network
  volumes:
    - ./logs/cryptobot:/app/logs
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
    interval: 30s
    timeout: 5s
    retries: 3
    start_period: 60s
  mem_limit: 1.5g
  cpus: 0.75
```

### 8.3 Submodule Update Workflow

Saat ada update di crypto-bot repo:

```bash
cd /root/axiom_core/agents/crypto_bot
git fetch origin
git checkout main  # atau branch yang relevan
git pull

cd /root/axiom_core
git add agents/crypto_bot
git commit -m "[infra] bump cryptobot submodule to {short-sha}"
git push

# Rebuild & redeploy
docker compose build cryptobot_main
docker compose up -d cryptobot_main
```

---

## 9. BACKUP & ROLLBACK PLAN

### 9.1 Daily Backup Cron

```bash
nano /etc/cron.d/axiom-backup
```

```cron
# Daily 03:00 WIB - backup Postgres
0 3 * * * root /root/axiom_core/scripts/backup_postgres.sh >> /var/log/axiom_backup.log 2>&1

# Weekly Senin 04:00 - upload ke Backblaze B2
0 4 * * 1 root /root/axiom_core/scripts/upload_to_b2.sh >> /var/log/axiom_backup.log 2>&1

# Daily 03:30 - rotate logs
30 3 * * * root /root/axiom_core/scripts/rotate_logs.sh >> /var/log/axiom_backup.log 2>&1
```

`scripts/backup_postgres.sh`:
```bash
#!/bin/bash
set -euo pipefail
BACKUP_DIR=/root/axiom_backups/postgres
DATE=$(date +%Y%m%d-%H%M%S)
mkdir -p $BACKUP_DIR

docker exec axiom_db pg_dump -U aru_admin -d axiom_memories | gzip > $BACKUP_DIR/axiom_memories-$DATE.sql.gz
docker exec axiom_db pg_dump -U aru_admin -d cryptobot_db | gzip > $BACKUP_DIR/cryptobot_db-$DATE.sql.gz

# Retention 30 hari lokal
find $BACKUP_DIR -name "*.sql.gz" -mtime +30 -delete

echo "$(date): backup complete" >> /var/log/axiom_backup.log
```

### 9.2 Rollback Plan ke Render

Jika migrasi VPS bermasalah dalam 7 hari pertama:

1. **JANGAN delete** Render service — hanya suspend
2. Suspend bot di VPS: `docker compose down cryptobot_main`
3. Re-activate Render service
4. Update Bybit IP whitelist kembali ke Render IP (kalau di-restrict)
5. Verify bot Render running normal
6. Investigate root cause di VPS, fix, dan re-attempt migrasi

⚠️ **Catatan**: Data trades di VPS post-migrasi **tidak otomatis** sync balik ke Supabase. Jika rollback dilakukan, ada gap data yang harus di-handle manual.

### 9.3 Disaster Recovery (Total VPS Loss)

Jika VPS terbakar / dihapus:

1. Provision VPS baru (Contabo)
2. Restore Backblaze B2 backup terbaru:
   ```bash
   b2 download-file-by-name axiom-backups postgres/cryptobot_db-{date}.sql.gz /tmp/
   gunzip /tmp/cryptobot_db-*.sql.gz
   docker exec -i axiom_db psql -U aru_admin -d cryptobot_db < /tmp/cryptobot_db-*.sql
   ```
3. Restore .env dari password manager
4. Restart full stack
5. Catat: 1-7 hari data trades terakhir mungkin hilang (tergantung last backup time)

---

## 10. POST-MIGRATION VALIDATION CHECKLIST

Setelah migrasi selesai (T+24 jam):

- [ ] All 11 Docker containers UP, healthy status
- [ ] PgBouncer connection pool: SHOW POOLS menampilkan koneksi aktif
- [ ] `cryptobot_main` log: trading loop "Cycle X" tiap 30 detik
- [ ] PnL tracking: `SELECT * FROM portfolio_state ORDER BY snapshot_date DESC LIMIT 1` menampilkan data terkini
- [ ] Trades baru ter-record: `SELECT count(*) FROM trades WHERE opened_at > now() - INTERVAL '6 hours'` > 0
- [ ] Telegram crypto-bot bot respond `/status` dengan info benar
- [ ] Telegram axiom bot respond
- [ ] Frontend dashboard accessible & login PIN works
- [ ] `https://your-domain.com/api/health` return 200
- [ ] No error log dalam `docker compose logs --tail=200`
- [ ] Disk usage `df -h /root` di bawah 50% (200 GB total, max 100 GB used)
- [ ] Memory usage `free -h` available > 2 GB
- [ ] CPU usage `htop` average < 50%
- [ ] Backup cron jalan: cek `/var/log/axiom_backup.log` setelah 03:00 WIB hari berikutnya
- [ ] Render service: **suspended** (bukan deleted)
- [ ] Bybit IP whitelist: pointing ke VPS IP

---

## CURRENT STATE

**Last sync:** 2026-04-27

- ✅ Strategi migrasi (Strategi A: Hot Cutover) terdokumentasi
- ✅ Database migration plan: pg_dump → load → hypertable convert
- ✅ Code migration plan: supabase-py → asyncpg dengan pattern reference
- ✅ VPS hardening checklist
- ✅ Docker stack startup sequence
- ✅ Nginx + Let's Encrypt setup
- ✅ Submodule replacement workflow
- ✅ Backup & rollback plan
- ✅ Post-migration validation checklist
- ⏳ Belum eksekusi migrasi — menunggu M1 (local setup) selesai dulu
- ⏳ asyncpg port di crypto-bot: belum di-PR ke `git@github.com:junadwi009/crypto-bot.git`
- ⏳ VPS belum di-provision

---

## NEXT ACTION

**Untuk Aru:**

1. **Selesaikan M1 (local setup)** dulu sebelum touch VPS — jangan loncat
2. Setelah M1 done: order VPS Contabo Cloud VPS 30 NVMe Ubuntu 24.04 LTS
3. Setelah VPS aktif: ikuti section 5-7 step-by-step
4. **JANGAN apply migrasi data Supabase** sampai schema lokal di VPS sudah final & ter-test

**Untuk Claude Code (saat diminta lanjut Phase 2):**

1. Verify M1 done (cek CURRENT STATE di **[CLAUDE_INSTRUCTIONS.md](./CLAUDE_INSTRUCTIONS.md)** dan **[DEVELOPMENT_ROADMAP.md](./DEVELOPMENT_ROADMAP.md#phase-1--local-setup--integration-validation)**)
2. Confirm VPS aktif dengan SSH test
3. Eksekusi step-by-step section 5-7 dengan **konfirmasi per step ke Aru** (jangan auto-execute)
4. Update CURRENT STATE di file ini setelah setiap section selesai
5. Stage 1 (asyncpg port di crypto-bot) **harus PR & merge dulu** sebelum deploy ke VPS — jangan deploy kode yang belum reviewed
