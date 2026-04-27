# DEVELOPMENT_ROADMAP.md — TAHAPAN & MILESTONE

> **Status:** AUTHORITATIVE | **Owner:** Aru (aru009)
> File ini definisikan **urutan kerja** dari setup awal hingga sistem fully autonomous.
> Update **wajib** dilakukan setiap milestone selesai (centang checkbox + update CURRENT STATE).

→ Prerequisite: **[CLAUDE_INSTRUCTIONS.md](./CLAUDE_INSTRUCTIONS.md)** sudah dibaca.

---

## OVERVIEW PHASES

```
┌─────────────────────────────────────────────────────────────────┐
│ PHASE 1: LOCAL SETUP (Hari 1)                                    │
│ ➜ Goal: kedua sistem (axiom + crypto-bot) jalan di lokal        │
│ ➜ Validation: 30 menit uptime tanpa crash, healthchecks pass    │
│ ➜ Milestone: M1                                                  │
├─────────────────────────────────────────────────────────────────┤
│ PHASE 2: MIGRATION TO VPS CONTABO (Hari 2-3)                     │
│ ➜ Goal: production deployment, Render service di-suspend        │
│ ➜ Validation: 7×24 jam paper trade tanpa intervensi             │
│ ➜ Milestone: M2                                                  │
├─────────────────────────────────────────────────────────────────┤
│ PHASE 3: AI CAPABILITIES LAYER 1+2 (Hari 4-10)                   │
│ ➜ Goal: pattern recognition + anomaly detection aktif           │
│ ➜ Validation: 50+ patterns discovered, 1 chaos detection event  │
│ ➜ Milestone: M3                                                  │
├─────────────────────────────────────────────────────────────────┤
│ PHASE 4: SELF-IMPROVING LOOP LAYER 3+4 (Hari 11-30 + ongoing)    │
│ ➜ Goal: parameter & code rewrite otonom (with HITL)             │
│ ➜ Validation: 5+ patches auto-applied tanpa rollback            │
│ ➜ Milestone: M4                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## PHASE 1 — LOCAL SETUP & INTEGRATION VALIDATION

**Target waktu**: 4-8 jam kerja
**Goal**: kedua sistem terkoneksi dan running di lokal (Windows dengan WSL2 atau Ubuntu native)

### Checklist Phase 1

#### 1.1 Persiapan Repo Local
- [ ] **Windows**: clone axiom-orchestrator ke `C:\Users\Aru\axiom-orchestrator\` via Git Bash atau WSL
  ```powershell
  cd C:\Users\Aru\
  git clone <axiom-repo-url> axiom-orchestrator
  cd axiom-orchestrator
  ```
- [ ] **Ubuntu**: clone axiom-orchestrator ke `~/axiom-orchestrator/`
  ```bash
  cd ~ && git clone <axiom-repo-url> axiom-orchestrator && cd axiom-orchestrator
  ```
- [ ] Hapus folder lama `agents/crypto_bot/` (yang berisi stub `bot.py`):
  - **Windows PowerShell**: `Remove-Item -Recurse -Force agents/crypto_bot`
  - **Ubuntu**: `rm -rf agents/crypto_bot`
- [ ] Tambah crypto-bot sebagai git submodule:
  ```bash
  git submodule add git@github.com:junadwi009/crypto-bot.git agents/crypto_bot
  git submodule update --init --recursive
  ```
- [ ] Verify struktur:
  - **Ubuntu**: `ls agents/crypto_bot/main.py`
  - **Windows PowerShell**: `Test-Path agents/crypto_bot/main.py`

#### 1.2 Setup Python Environment
- [ ] **Windows**:
  ```powershell
  # Install Python 3.11 dari python.org jika belum ada
  py -3.11 -m venv .venv-axiom
  .\.venv-axiom\Scripts\Activate.ps1
  pip install -r requirements.txt
  
  # Crypto-bot pakai Python 3.11.9 spesifik
  cd agents\crypto_bot
  py -3.11 -m venv .venv-cryptobot
  .\.venv-cryptobot\Scripts\Activate.ps1
  pip install -r requirements.txt
  cd ..\..
  ```
- [ ] **Ubuntu**:
  ```bash
  # Install Python 3.11 jika belum
  sudo apt update && sudo apt install -y python3.11 python3.11-venv python3.11-dev
  
  python3.11 -m venv .venv-axiom
  source .venv-axiom/bin/activate
  pip install -r requirements.txt
  
  cd agents/crypto_bot
  python3.11 -m venv .venv-cryptobot
  source .venv-cryptobot/bin/activate
  pip install -r requirements.txt
  cd ../..
  ```

#### 1.3 Setup Docker
- [ ] Verifikasi Docker terinstall:
  - `docker --version` → minimum Docker 24+
  - `docker compose version` → minimum v2.0+
- [ ] **Windows**: Docker Desktop untuk Windows dengan WSL2 backend (recommended)
- [ ] **Ubuntu**: Docker Engine + docker-compose-plugin via apt

#### 1.4 Configure .env
- [ ] Copy `.env.example` ke `.env`:
  - **Windows**: `Copy-Item .env.example .env`
  - **Ubuntu**: `cp .env.example .env`
- [ ] Edit `.env` dengan kredensial Aru (minimum untuk M1):
  ```env
  # Bybit (testnet OK untuk M1)
  BYBIT_API_KEY=your_testnet_key
  BYBIT_API_SECRET=your_testnet_secret
  BYBIT_TESTNET=true
  
  # Anthropic (untuk crypto-bot brain)
  ANTHROPIC_API_KEY=sk-ant-...
  ANTHROPIC_SPENDING_LIMIT=5  # batas $5 untuk testing M1
  
  # OpenRouter (untuk axiom council)
  OPENROUTER_API_KEY=sk-or-...
  
  # Telegram - DUA TOKEN
  TELEGRAM_BOT_TOKEN_AXIOM=...
  TELEGRAM_BOT_TOKEN_CRYPTOBOT=...
  TELEGRAM_CHAT_ID=...
  
  # Database (untuk M1, lokal Docker)
  DB_HOST=localhost
  DB_PORT=5432  # langsung ke axiom_db (PgBouncer di-skip untuk M1)
  DB_USER_AXIOM=axiom_user
  DB_PASSWORD_AXIOM=axiom_local_dev_password
  DB_USER_CRYPTOBOT=cryptobot_user
  DB_PASSWORD_CRYPTOBOT=cryptobot_local_dev_password
  DB_USER_OBSERVER=readonly_observer
  DB_PASSWORD_OBSERVER=observer_local_dev_password
  
  # Redis
  REDIS_URL=redis://localhost:6379
  REDIS_PASSWORD=
  
  # Bot Behavior
  PAPER_TRADE=true
  INITIAL_CAPITAL=213
  DAILY_TARGET_PCT=3.0
  
  # Auth
  BOT_PIN_HASH=  # generate dengan: python -c "import hashlib; print(hashlib.sha256('1234'.encode()).hexdigest())"
  ```
- [ ] **Windows**: gunakan editor seperti VSCode atau Notepad++ untuk edit `.env` (jangan Notepad, dia tambah BOM)
- [ ] **Ubuntu**: `nano .env` atau `vim .env`

#### 1.5 Spin Up Docker Services
- [ ] Pastikan `docker-compose.yaml` sudah update sesuai **[ARCHITECTURE.md](./ARCHITECTURE.md#5-deployment-topology)** section 5.1
- [ ] Build images:
  - **Windows / Ubuntu**: `docker compose build`
- [ ] Start core services (db, redis, n8n) dulu:
  ```bash
  docker compose up -d axiom_db axiom_redis axiom_n8n
  ```
- [ ] Verify containers running: `docker ps` → harus ada 3 container UP
- [ ] Wait 30 detik untuk Postgres init complete, lalu verify:
  ```bash
  docker exec axiom_db psql -U aru_admin -d axiom_memories -c \
    "SELECT count(*) FROM knowledge_base;"
  ```

#### 1.6 Initialize Database Schema
- [ ] Schema axiom_memories sudah otomatis ter-load dari `init.sql` (mounted di docker-compose). Verify:
  ```bash
  docker exec axiom_db psql -U aru_admin -d axiom_memories -c \
    "SELECT hypertable_name FROM timescaledb_information.hypertables;"
  ```
  Output expected: `ares_market_scans, axiom_evaluations, cross_exchange_signals`
- [ ] Schema cryptobot_db: load `init_cryptobot_db.sql`:
  ```bash
  docker exec -i axiom_db psql -U aru_admin < init_cryptobot_db.sql
  ```
- [ ] Verify cryptobot_db hypertables:
  ```bash
  docker exec axiom_db psql -U aru_admin -d cryptobot_db -c \
    "SELECT hypertable_name FROM timescaledb_information.hypertables;"
  ```
  Output expected: `trades, bot_events, news_items, claude_usage`

#### 1.7 Start Crypto-bot
- [ ] Crypto-bot pakai `.env` di root `agents/crypto_bot/.env` (terpisah dari axiom). Buat:
  ```bash
  cd agents/crypto_bot
  cp .env.example .env  # jika ada di repo crypto-bot
  ```
  Atau symlink ke root:
  - **Ubuntu**: `ln -s ../../.env .env`
  - **Windows**: skip symlink, copy file (`Copy-Item ..\..\.env .env`)
- [ ] Update `agents/crypto_bot/config/settings.py` agar **tidak** error tanpa Supabase URL (akan di-fix proper di Phase 2). Untuk M1: pastikan `SUPABASE_URL` & `SUPABASE_SERVICE_KEY` di `.env` di-isi dengan dummy value, atau patch sementara untuk fallback ke local Postgres
- [ ] Start crypto-bot manual dulu (bukan via Docker, untuk debug mudah):
  ```bash
  # Ubuntu
  cd agents/crypto_bot && source .venv-cryptobot/bin/activate && python main.py
  
  # Windows
  cd agents\crypto_bot
  .\.venv-cryptobot\Scripts\Activate.ps1
  python main.py
  ```
- [ ] Verify FastAPI up: `curl http://localhost:8000/health` → 200 OK
- [ ] Verify Telegram bot crypto-bot respond: di chat Telegram, kirim `/status` ke bot crypto-bot
- [ ] Verify trading loop running: log harus print "Bot started in PAPER mode" + every 30s "Cycle X: scanning N pairs"

#### 1.8 Start Axiom
- [ ] Di terminal terpisah:
  ```bash
  # Ubuntu
  source .venv-axiom/bin/activate && python orchestrator.py
  
  # Windows
  .\.venv-axiom\Scripts\Activate.ps1
  python orchestrator.py
  ```
- [ ] Verify log: "Sidang Dewan Axiom dimulai..." + "Connected to Postgres axiom_memories"
- [ ] Test Telegram bot axiom: kirim command via bot axiom (token ke-2)
- [ ] Verify axiom-bridge: `docker logs axiom_bridge` → "Listening on Redis BLPOP queue"

#### 1.9 Validation M1
- [ ] **Sukses M1 jika semua benar**:
  - 3 Docker containers UP (db, redis, n8n)
  - Crypto-bot FastAPI healthcheck 200 OK
  - Crypto-bot trading loop logs cycle every 30s
  - Axiom orchestrator connected to DB
  - Kedua Telegram bot respond ke command
  - Run minimum 30 menit tanpa crash
- [ ] Update `## CURRENT STATE` di **[CLAUDE_INSTRUCTIONS.md](./CLAUDE_INSTRUCTIONS.md)** dan file ini

### Phase 1 — Risk & Mitigation

| Risk | Mitigation |
|---|---|
| Supabase coupling di crypto-bot fail di local | Phase 1 boleh patch `database/client.py` sementara untuk fallback ke local Postgres. Real fix di Phase 2 |
| Telegram polling collision (dua bot beda token tapi sama chat_id) | Pastikan token berbeda, namespace command juga sebaiknya beda (axiom: `/ax_status`, cryptobot: `/cb_status`) |
| Bybit testnet API key salah → connection error | Verify dengan `python -c "from pybit.unified_trading import HTTP; print(HTTP(testnet=True, api_key='X', api_secret='Y').get_wallet_balance(accountType='UNIFIED'))"` |
| TimescaleDB extension tidak load | Image `timescale/timescaledb:latest-pg16` sudah include extension. Verify: `SELECT extname FROM pg_extension;` should include `timescaledb` |

---

## PHASE 2 — MIGRATION RENDER → VPS CONTABO

**Target waktu**: 16-24 jam kerja (terbagi 2-3 hari)
**Goal**: production deployment di VPS Contabo, Render service suspended

### 2.1 Provision VPS

- [ ] Pesan **Cloud VPS 30 NVMe** (atau VPS 20 NVMe sebagai minimum) di Contabo
- [ ] Pilih OS: **Ubuntu 24.04 LTS**
- [ ] Tunggu provisioning (biasanya 5-15 menit)
- [ ] Catat IP public VPS, simpan di password manager

### 2.2 VPS Initial Setup

```bash
# SSH dari laptop Aru ke VPS
ssh root@{vps_ip}

# Update sistem
apt update && apt upgrade -y

# Install dependencies
apt install -y curl git ufw fail2ban nano htop

# Setup user non-root (optional, untuk keamanan)
adduser aru009 && usermod -aG sudo aru009

# Setup SSH key login (rekomendasi keamanan)
mkdir -p ~/.ssh && echo "your_pubkey" >> ~/.ssh/authorized_keys

# Disable password login
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh

# Setup firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 5678/tcp comment 'n8n (TODO: restrict to home IP)'
ufw enable
```

### 2.3 Install Docker

```bash
# Install Docker via official script
curl -fsSL https://get.docker.com | sh

# Install docker-compose plugin
apt install -y docker-compose-plugin

# Verify
docker --version  # >=24
docker compose version  # >=2.0

# Setup non-root docker access (jika pakai user aru009)
usermod -aG docker aru009
```

### 2.4 Clone Repo & Submodule

```bash
mkdir -p /root/axiom_core
cd /root/axiom_core

# Clone axiom
git clone <axiom-repo-url> .

# Initialize submodule
git submodule update --init --recursive

# Verify
ls agents/crypto_bot/main.py
```

### 2.5 Migration Database dari Supabase

→ Detail lengkap: **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md#database-migration)**.

Ringkasan:
1. Dump schema dari Supabase: `pg_dump --schema-only ...`
2. Dump data dari Supabase: `pg_dump --data-only ...`
3. Apply schema ke local Postgres (di VPS)
4. Convert tabel ke hypertable
5. Load data
6. Validate row counts match

### 2.6 Code Migration: supabase-py → asyncpg

Patch `agents/crypto_bot/database/client.py` (perlu PR ke crypto-bot repo):
- Replace `from supabase import create_client` → `import asyncpg`
- Replace pool initialization
- Convert query syntax dari fluent API ke SQL parametrized

→ Detail: **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md#code-migration-supabase--asyncpg)**.

### 2.7 Configure Production .env

```bash
nano /root/axiom_core/.env
# Isi semua kredensial production (lihat .env.example)
chmod 600 /root/axiom_core/.env
```

### 2.8 Build & Start Stack

```bash
cd /root/axiom_core
docker compose build
docker compose up -d
docker ps  # verify all 11 containers UP
```

### 2.9 Setup Nginx + Let's Encrypt (Frontend Deployment)

```bash
# Install Certbot
apt install -y certbot python3-certbot-nginx

# Pastikan domain sudah point ke VPS IP (DNS A record)
certbot --nginx -d your-domain.com

# Build frontend
cd /root/axiom_core/agents/crypto_bot/frontend
# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs
npm install
npm run build

# Copy dist to nginx serve folder
mkdir -p /var/www/cryptobot
cp -r dist/* /var/www/cryptobot/

# Configure nginx (file /etc/nginx/sites-available/cryptobot)
# Reverse proxy /api/* ke localhost:8000
# Static serve /var/www/cryptobot untuk /
```

→ nginx config detail: **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md#frontend-deployment)**.

### 2.10 Validation M2

- [ ] All 11 containers UP and healthy
- [ ] Crypto-bot Telegram bot respond
- [ ] Axiom Telegram bot respond
- [ ] Frontend dashboard accessible at https://your-domain.com
- [ ] Crypto-bot trading loop logs cycle every 30s
- [ ] Aru can `/status`, `/pause`, `/resume` via Telegram
- [ ] **PAPER mode** running 7×24 jam without restart
- [ ] Daily backup cron job verified (`crontab -l` di host)
- [ ] Render service di-suspend (jangan delete dulu — backup option)
- [ ] DNS pointing ke VPS IP

### Phase 2 — Risk & Mitigation

| Risk | Mitigation |
|---|---|
| Supabase data hilang saat migrasi | Pre-migration: `pg_dump` ke local laptop sebagai backup eksternal |
| asyncpg port di crypto-bot bug → trading loop crash | Test asyncpg port di local M1 environment dulu sebelum deploy ke VPS |
| Render env vars terlewat → bot crash di VPS | Audit semua env vars di `render.yaml` vs `.env.example` di repo, ensure 1:1 mapping |
| DNS propagation lama | Plan migrasi minimum 6 jam sebelum cutover, gunakan low-TTL (60s) sebelum migrasi |
| Bybit IP whitelist masih point ke Render IP | Update IP whitelist di Bybit dashboard ke VPS IP **sebelum** start trading |

---

## PHASE 3 — AI CAPABILITIES LAYER 1+2 (HARI 4-10)

**Target waktu**: 1 minggu kerja (5-7 hari)
**Goal**: pattern recognition + anomaly detection aktif, axiom mulai "belajar"

### 3.1 Build Container `axiom_pattern`

- [ ] Buat `Dockerfile.pattern` untuk container ML:
  ```dockerfile
  FROM python:3.11-slim
  WORKDIR /app
  COPY requirements_pattern.txt .
  RUN pip install -r requirements_pattern.txt
  COPY agents/axiom_pattern/ ./agents/axiom_pattern/
  COPY core_memory/ ./core_memory/
  CMD ["python", "-m", "agents.axiom_pattern.main"]
  ```
- [ ] `requirements_pattern.txt`: scikit-learn, pandas, numpy, hmmlearn, vectorbt, asyncpg, redis, apscheduler, ccxt
- [ ] Update `docker-compose.yaml` tambah service `axiom_pattern`

### 3.2 Implement Layer 1A — Time-Series Anomaly Detector

- [ ] File `agents/axiom_pattern/anomaly_detector.py` (lihat **[AI_CAPABILITIES.md](./AI_CAPABILITIES.md#layer-1--pattern-recognition)** section 2.1A)
- [ ] Schedule: tiap 5 menit via apscheduler
- [ ] Output: insert ke `pattern_discoveries`
- [ ] Test: jalankan 24 jam, verify minimum 5 candidate pattern terdeteksi

### 3.3 Implement Layer 1B — Order Book Pattern Miner

- [ ] **Crypto-bot side** (PR ke crypto-bot repo):
  - File `engine/orderbook_capturer.py` (capture loop tiap 30s, INSERT ke `orderbook_snapshots`)
  - Migration: `001_add_orderbook_snapshots.sql`
- [ ] **Axiom side**: `agents/axiom_pattern/orderbook_miner.py`
- [ ] Schedule: tiap 5 menit
- [ ] Test: 48 jam capture loop, minimum 1 iceberg/spoofing candidate ditemukan

### 3.4 Implement Layer 1C — Volume Profile

- [ ] File `agents/axiom_pattern/volume_profile.py`
- [ ] Schedule: daily 00:00 WIB
- [ ] Output: insert ke `pattern_discoveries` dengan POC/VAH/VAL per pair
- [ ] Set Redis key `axiom:vp:{pair}` untuk consumed crypto-bot rule_based

### 3.5 Implement Layer 1D — Cross-Exchange Divergence

- [ ] File `agents/axiom_pattern/cross_exchange_monitor.py`
- [ ] ccxt fetch ticker dari Bybit, Binance, OKX, Bitget
- [ ] Schedule: tiap 60 detik
- [ ] Output: `cross_exchange_signals` table

### 3.6 Implement Layer 2 — Anomaly Detection

- [ ] Implementasi 4 detector:
  - [ ] `regime_classifier.py` (HMM 3-state)
  - [ ] `liquidity_monitor.py`
  - [ ] `correlation_monitor.py`
  - [ ] `news_shock_monitor.py`
- [ ] Wire ke Redis flag (`shared:bot_paused`, `shared:circuit_breaker_tripped`)
- [ ] Telegram alert ke axiom-telegram saat detection trigger

### 3.7 Build `axiom_consensus` Container

- [ ] Container baru untuk weekly dual-brain consensus
- [ ] Schedule: Sunday 04:00 WIB (setelah Opus weekly result available di `opus_memory`)
- [ ] Logic: read latest opus_memory + run Hermes Council debat → consensus_log

### 3.8 Validation M3

- [ ] `pattern_discoveries` table populated dengan ≥50 unique patterns dalam 7 hari
- [ ] Minimum 1 chaos regime detected via HMM (real or test data)
- [ ] Cross-exchange divergence detected (ada pair dengan spread >20bps)
- [ ] News shock alert pernah trigger (cek `bot_events` history)
- [ ] Weekly consensus run berhasil minimum 1× — `consensus_log` ada row

### Phase 3 — Risk & Mitigation

| Risk | Mitigation |
|---|---|
| ML model overfit ke market kondisi tertentu | Walk-forward validation, retraining weekly |
| HMM state mapping ambigu (state 0/1/2 mana yang chaos?) | Post-training: hitung mean variance per state, urutkan ascending — index tertinggi = chaos |
| ccxt rate limit dari multi-exchange query | Implement caching 30s + jitter sleep antar exchange call |
| Pattern false positive overwhelm Aru via Telegram | Threshold tuning: alert hanya untuk pattern dengan precision ≥0.7 setelah validation |

---

## PHASE 4 — SELF-IMPROVING LOOP (HARI 11-30 + ONGOING)

**Target waktu**: 2-3 minggu untuk Layer 3a, kemudian ongoing untuk Layer 4
**Goal**: parameter & code rewrite otonom

### 4.1 Implement Layer 3a — Multi-Armed Bandit

- [ ] File `agents/axiom_rl/thompson_bandit.py`
- [ ] State: tuple (pair, regime), 64 arms per state
- [ ] Reward computation: realized PnL window 24h post parameter change
- [ ] Persist bandit posterior di Redis (`axiom:bandit:{pair}:{regime}` JSON)
- [ ] Integrasi dengan `axiom_proposals` workflow: bandit picks arm → propose param change

### 4.2 Implement Layer 3c — Validator

- [ ] File `agents/axiom_rl/proposal_validator.py`
- [ ] Backtest 30-day walk-forward
- [ ] Risk constraint check
- [ ] Statistical significance test
- [ ] Update status di `axiom_proposals`: validated/rejected

### 4.3 Implement `parameter_sync` Worker

- [ ] Container baru `cryptobot_param_sync` di docker-compose
- [ ] File `agents/parameter_sync/worker.py` (poll axiom_proposals, apply approved)
- [ ] Auto-rollback monitor: cron 1 jam selama 24 jam post-apply

### 4.4 Implement Layer 4 — Self-Modifying Logic

⚠️ **JANGAN aktifkan sampai Layer 3a stabil minimum 30 hari.**

- [ ] File `agents/axiom_consensus/code_proposal_generator.py`
- [ ] Auto-validator: pylint + pytest + backtest
- [ ] Asura safety review (rule-based static analysis)
- [ ] Telegram approval workflow (button-based via inline keyboard)
- [ ] Git apply + rolling restart logic

### 4.5 Validation M4

- [ ] Layer 3a: minimum 5 parameter rewrite proposals applied tanpa rollback dalam 30 hari
- [ ] Layer 4: minimum 3 code patch applied tanpa rollback dalam 30 hari
- [ ] Auto-rollback **terbukti bekerja**: 1 patch sengaja flawed → ter-revert otomatis dalam 24 jam
- [ ] Win rate naik dari baseline ke ≥58%
- [ ] Sistem berjalan otonom 14 hari berturut-turut tanpa intervensi manual

### Phase 4 — Risk & Mitigation

| Risk | Mitigation |
|---|---|
| Bandit converge ke arm sub-optimal | Add epsilon-greedy 5% random exploration |
| Code patch breaks runtime di edge case | Auto-rollback monitor + comprehensive pytest |
| Aru tidak available untuk approval saat patch validated | Email backup notification, fallback dashboard auth |
| Auto-rollback false trigger di volatile market | Grace period 24h post-apply sebelum auto-rollback active |

---

## ONGOING — POST-M4

Setelah M4 validated:

- **30 hari pertama**: monitor metrics weekly, fine-tune thresholds
- **60 hari**: review apakah switch ke selective autonomy (auto-approve patches dengan ≥3σ improvement)
- **180 hari**: review apakah switch ke fully autonomous mode
- **Quarterly**: rotate API keys (Bybit, Anthropic, OpenRouter)
- **Quarterly**: review whitelist file untuk Layer 4 — boleh expand jika trust earned

---

## DEPENDENCY MATRIX

| Phase | Depends On | Blocks |
|---|---|---|
| P1 (Local) | Repo clone, Docker install, kredensial | P2 |
| P2 (Migrasi) | P1 done, VPS provisioned, domain | P3, production trading |
| P3 (Layer 1+2) | P2 done, 30+ hari trade data | P4 |
| P4 Layer 3a | P3 done, 90+ hari trade data | P4 Layer 4 |
| P4 Layer 4 | Layer 3a stabil 30 hari, ≥30 successful proposals | Full autonomy |

---

## CURRENT STATE

**Last sync:** 2026-04-27

- ✅ Phase 1-4 timeline & checklist terdefinisi
- ✅ Risk matrix per phase terdokumentasi
- ✅ Dependency graph jelas
- ⏳ **Phase 1: BELUM dimulai** — Aru perlu eksekusi M1 checklist
- ⏳ Phase 2: pending P1
- ⏳ Phase 3: pending P2
- ⏳ Phase 4: pending P3

---

## NEXT ACTION

**Untuk Aru:**

1. **Eksekusi Phase 1 checklist** sesuai urutan, jangan skip step
2. Setelah M1 validated → centang checkbox di file ini, commit ke git
3. Order VPS Contabo Cloud VPS 30 NVMe Ubuntu 24.04 LTS
4. Begitu VPS aktif → masuk Phase 2

**Untuk Claude Code (jika diminta lanjut Phase 2+):**

1. Verify P1 selesai (cek CURRENT STATE di file ini)
2. Baca **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md)** sebelum touch VPS
3. Eksekusi step-by-step **dengan cek per step ke Aru** (jangan auto-execute semua)
4. Update checklist seiring progress
