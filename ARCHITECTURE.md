# ARCHITECTURE.md — PETA SISTEM LENGKAP

> **Status:** AUTHORITATIVE | **Owner:** Aru (aru009)
> Setiap perubahan arsitektur **wajib** tercatat di sini sebelum implementasi.
> File ini adalah **source of truth** untuk struktur sistem.

→ Sebelum baca file ini, pastikan sudah baca **[CLAUDE_INSTRUCTIONS.md](./CLAUDE_INSTRUCTIONS.md)** terlebih dahulu.

---

## 1. PHILOSOPHY — IDENTITAS SISTEM

Axiom + crypto-bot adalah **dua entitas yang saling melengkapi**, bukan parent-child:

```
                    ┌──────────────────────────────┐
                    │         AXIOM (BRAIN)         │
                    │  AI Developer Team & Observer │
                    │  • Multi-agent council debat  │
                    │  • Pattern recognition        │
                    │  • Parameter rewrite proposer │
                    │  • Code change proposer       │
                    │  • Self-improvement loop      │
                    └──────────────┬───────────────┘
                                   │ observasi + intervensi
                                   │ (lewat parameter, prompt, kode)
                                   ▼
                    ┌──────────────────────────────┐
                    │     CRYPTO-BOT (PRODUCT)      │
                    │   Autonomous Trading Engine   │
                    │  • rule_based engine          │
                    │  • Haiku → Sonnet pipeline    │
                    │  • Position management        │
                    │  • Order execution            │
                    │  • News integration           │
                    │  • Telegram dashboard         │
                    └───────────────────────────────┘
```

**Crypto-bot** memutuskan trading **secara otonom** dengan brain stack-nya sendiri (Haiku/Sonnet). Crypto-bot **TIDAK** menunggu sinyal dari axiom untuk eksekusi.

**Axiom** mengamati keputusan crypto-bot, mempelajari pola, lalu **mengubah konfigurasi & kode** crypto-bot agar keputusannya makin tajam. Axiom **TIDAK** mengirim sinyal trading langsung.

→ Detail mekanisme intervensi: lihat **[INTEGRATION_GUIDE.md](./INTEGRATION_GUIDE.md#mekanisme-intervensi-axiom)**.

---

## 2. IDENTITAS KOMPONEN

### 2.1 Axiom Orchestrator (Brain)

| Attribute | Value |
|---|---|
| Repo | local: `/root/axiom_core/` (VPS) |
| Bahasa | Python 3.10+ |
| Framework agen | Microsoft AutoGen 0.2.20 |
| LLM provider | OpenRouter (Hermes-3 70B + Hermes-4 70B) |
| Library tambahan | `ccxt` (multi-exchange intel), `psycopg2-binary`, `redis-py`, `python-telegram-bot` |
| Komunikasi | Redis pub/sub + BLPOP queue + DB write |
| Telegram bot | bot dedicated dengan token `TELEGRAM_BOT_TOKEN_AXIOM` |
| Persistensi | PostgreSQL `axiom_memories` database (di server yang sama dengan crypto-bot) |

**Tanggung jawab spesifik axiom:**
1. **Observation** — read-only access ke semua tabel crypto-bot (`trades`, `bot_events`, `opus_memory`, dll)
2. **Pattern Recognition** — running di background tiap 5 menit, scan `ares_market_scans` & cross-exchange data
3. **Council Debate** — 8 agen Hermes berdebat saat Aru kirim command via Telegram, hasil keputusan disimpan di `axiom_evaluations`
4. **Parameter Rewrite Proposal** — dari pattern + outcome, generate proposed parameter changes → write ke `axiom_proposals`
5. **Code Change Proposal** — untuk perubahan strategi non-trivial, generate diff → write ke `code_change_audit`
6. **Consensus Engine** — bandingkan output Opus mingguan crypto-bot dengan output Council axiom; tulis ke `consensus_log`
7. **Multi-exchange intelligence** — pakai ccxt untuk monitor harga di Bybit + Binance + OKX, deteksi divergence → simpan di `cross_exchange_signals`

### 2.2 Crypto-Bot (Product)

| Attribute | Value |
|---|---|
| Repo | `git@github.com:junadwi009/crypto-bot.git` (sub-module di `agents/crypto_bot/`) |
| Bahasa | Python 3.11.9 (pinned) |
| Framework | FastAPI + asyncio + pybit (unified_trading) |
| LLM provider | Anthropic API direct (Claude Haiku 4.5, Sonnet 4.6, Opus weekly) |
| Library | pybit, anthropic, supabase-py (akan di-replace ke psycopg2/asyncpg post-migrasi), apscheduler, vectorbt, pandas-ta-classic |
| Komunikasi | FastAPI REST endpoints (port 8000) + Telegram polling |
| Telegram bot | bot dedicated dengan token `TELEGRAM_BOT_TOKEN_CRYPTOBOT` |
| Persistensi | PostgreSQL `cryptobot_db` database (di server yang sama dengan axiom) |

**Tanggung jawab spesifik crypto-bot:**
1. **Trading loop** — setiap 30 detik scan active pairs, generate signal lewat pipeline rule_based → Haiku → Sonnet → execute via pybit
2. **Position management** — monitor SL/TP, close positions, track open orders
3. **News pipeline** — fetch RSS + CryptoPanic tiap 15 menit, analisis sentiment via Haiku, trigger signal jika urgency tinggi
4. **Self-evaluation (Opus weekly)** — tiap minggu, Opus review trades + portfolio_state, write ke `opus_memory`
5. **Telegram dashboard** — interactive bot dengan PIN auth, command `/status`, `/pause`, `/resume`, `/stats`
6. **Health & observability** — FastAPI endpoint `/health`, `/status`, `/metrics` untuk dashboard frontend
7. **Circuit breaker** — auto-pause saat daily drawdown ≥ 15%
8. **Tier auto-progression** — saat capital naik melewati threshold tier, auto-update `pair_config` untuk aktifkan pair baru

### 2.3 Frontend Dashboard

| Attribute | Value |
|---|---|
| Lokasi | `agents/crypto_bot/frontend/` (sub-folder di repo crypto-bot) |
| Framework | React 18 + Vite |
| Styling | (lihat `frontend/package.json` untuk detail) |
| Deploy | nginx static di VPS yang sama, port 80/443 (lewat reverse proxy) |
| Auth | PIN login (validasi via FastAPI `/api/auth/login`) |
| Data source | FastAPI di `http://localhost:8000/api/*` |

→ Detail frontend deployment di VPS: **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md#frontend-deployment)**.

---

## 3. DATABASE LAYER

**Stack final**: PostgreSQL 16 + TimescaleDB 2.x extension + PgBouncer + Redis 7.

→ Schema lengkap: **[DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md)**.

### 3.1 Topology

```
┌─────────────────────────────────────────────────────────┐
│  Container: axiom_db                                     │
│  Image: timescale/timescaledb:latest-pg16                │
│  Volume: ./data/postgres_data:/var/lib/postgresql/data   │
│                                                          │
│  ├── DB: axiom_memories     (axiom-only tables)          │
│  │   ├── knowledge_base                                  │
│  │   ├── kai_ledger                                      │
│  │   ├── ares_market_scans          [hypertable]         │
│  │   ├── axiom_evaluations          [hypertable]         │
│  │   ├── consensus_log                                   │
│  │   ├── parameter_versions                              │
│  │   ├── pattern_discoveries                             │
│  │   ├── intervention_log                                │
│  │   ├── code_change_audit                               │
│  │   ├── axiom_proposals                                 │
│  │   └── cross_exchange_signals     [hypertable]         │
│  │                                                       │
│  └── DB: cryptobot_db       (ex-Supabase tables)         │
│      ├── trades                     [hypertable]         │
│      ├── portfolio_state                                 │
│      ├── strategy_params                                 │
│      ├── pair_config                                     │
│      ├── opus_memory                                     │
│      ├── news_items                 [hypertable]         │
│      ├── news_weights                                    │
│      ├── claude_usage               [hypertable]         │
│      ├── bot_events                 [hypertable]         │
│      ├── infra_fund                                      │
│      ├── tier_history                                    │
│      └── backtest_results                                │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Container: axiom_redis                                  │
│  Image: redis:7-alpine                                   │
│  Volume: ./data/redis_data:/data                         │
│  Config: appendonly yes (AOF persistence)                │
│                                                          │
│  Namespace: bot:*       (crypto-bot ephemeral state)     │
│  Namespace: axiom:*     (axiom queues + flags)           │
│  Namespace: shared:*    (cross-service flags)            │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  Container: axiom_pgbouncer                              │
│  Image: edoburu/pgbouncer:latest                         │
│  Port: 6432                                              │
│  Mode: transaction pooling                               │
│  Max client conn: 200, Pool size per DB: 25              │
└─────────────────────────────────────────────────────────┘
```

### 3.2 Cross-Service Access Rules

| Service | Akses ke `axiom_memories` | Akses ke `cryptobot_db` |
|---|---|---|
| `axiom-brain` (orchestrator) | Read+Write | **Read-only** (observasi) |
| `axiom-bridge`, `axiom-thanatos`, `axiom-telegram` | Read+Write | Read-only |
| `crypto-bot` (main.py) | **Read-only** (jika perlu cek konsensus) | Read+Write |
| `parameter-sync` (worker khusus) | Read | Read+Write (apply approved proposals) |
| `n8n` | Read+Write (workflow data) | Read-only |
| Dashboard FastAPI | Read | Read |

Enforcement: pakai role/user terpisah di Postgres (mis. `axiom_user`, `cryptobot_user`, `readonly_observer`, `parameter_sync_user`) dengan GRANT yang sesuai.

→ Detail GRANT statements: **[DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md#access-control)**.

---

## 4. COMMUNICATION LAYER

### 4.1 Channel Komunikasi & Tujuannya

| Channel | Producer | Consumer | Payload | Latency target |
|---|---|---|---|---|
| Redis BLPOP `axiom:command_queue` | `axiom-telegram` | `axiom-brain` | command Aru | < 100ms |
| Redis BLPOP `axiom:claw_tasks` | `axiom-brain` | `axiom-bridge` | task ke n8n | < 100ms |
| Redis BLPOP `axiom:claw_tasks_failed` | `axiom-bridge` | `axiom-thanatos` | task gagal | < 1s |
| Redis pub/sub `axiom:bot_events` | `crypto-bot` | `axiom-brain` (subscriber) | event stream (trade open/close, signal, error) | < 200ms |
| Redis SET/GET `shared:bot_paused` | `axiom-brain` (set), `crypto-bot` (read) | mutual | flag pause | instant |
| Redis SET/GET `shared:circuit_breaker_tripped` | `crypto-bot` (set), `axiom-brain` (read) | mutual | circuit breaker state | instant |
| Postgres listen/notify `crypto_bot.bot_events_inserted` | crypto-bot trigger | `axiom-brain` | new event signal | < 500ms |
| FastAPI REST `http://localhost:8000/api/*` | dashboard frontend, axiom (occasionally) | `crypto-bot` | dashboard queries, axiom diagnostic | < 200ms |
| Postgres `axiom_proposals` table | `axiom-brain` (insert) | `parameter-sync` worker (poll) | parameter change proposal | poll every 60s |
| Git commit ke branch `axiom/auto/{date}` | `axiom-brain` (commit) | `parameter-sync` worker (`git pull` + reload crypto-bot) | code change | pollable, on-demand |

### 4.2 Anti-Pattern yang DILARANG

❌ **Direct trading signal injection**: Axiom **TIDAK BOLEH** push ke `bybit_execution_queue` (queue legacy dari arsitektur lama). Crypto-bot punya pipeline-nya sendiri.

❌ **Cross-database direct write**: Axiom **TIDAK BOLEH** UPDATE `cryptobot_db.trades` langsung. Kalau axiom mau intervensi, harus lewat `axiom_proposals` → `parameter-sync`.

❌ **Sync HTTP call dari trading hot-path**: Crypto-bot's `signal_generator.process()` jangan call HTTP ke axiom (latensi mematikan untuk scalping). Komunikasi axiom→crypto-bot wajib via DB poll atau Redis pub/sub.

❌ **Telegram cross-bot polling**: Dua bot pakai **dua token berbeda**, tidak boleh share token (Telegram getUpdates race condition).

---

## 5. DEPLOYMENT TOPOLOGY (VPS Contabo, Ubuntu 24.04 LTS)

### 5.1 Container Stack

11 container dalam satu Docker network `axiom-network`:

```
┌──────────────────────────────────────────────────────────────────┐
│  VPS Contabo Cloud VPS 30 NVMe (4 vCPU / 12 GB RAM / 200 GB)     │
│  OS: Ubuntu 24.04 LTS  | Docker 26+ | docker-compose v2          │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  axiom-network (bridge driver)                              │  │
│  │                                                              │  │
│  │  Persistent layer:                                           │  │
│  │  • axiom_db          (timescaledb/timescaledb pg16)         │  │
│  │  • axiom_redis       (redis:7-alpine)                        │  │
│  │  • axiom_pgbouncer   (edoburu/pgbouncer)                    │  │
│  │                                                              │  │
│  │  Workflow layer:                                             │  │
│  │  • axiom_n8n         (n8nio/n8n:latest, port 5678)          │  │
│  │                                                              │  │
│  │  Axiom layer:                                                │  │
│  │  • axiom_brain       (orchestrator + Hermes Council)         │  │
│  │  • axiom_bridge      (Redis → n8n webhook)                   │  │
│  │  • axiom_thanatos    (failover monitor)                      │  │
│  │  • axiom_telegram    (telegram_gateway, axiom bot token)     │  │
│  │  • axiom_pattern     (Layer 1 ML: anomaly detection, NEW)    │  │
│  │  • axiom_consensus   (Layer 2: dual-brain weekly, NEW)       │  │
│  │                                                              │  │
│  │  Crypto-bot layer:                                           │  │
│  │  • cryptobot_main    (autonomous trading bot, port 8000)     │  │
│  │  • cryptobot_param_sync  (worker poll axiom_proposals, NEW)  │  │
│  │                                                              │  │
│  │  Edge layer:                                                 │  │
│  │  • axiom_nginx       (reverse proxy + frontend static)       │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  Network ports exposed ke internet (via UFW):                     │
│  • 22    SSH                                                      │
│  • 80    HTTP (redirect ke HTTPS via Let's Encrypt + certbot)     │
│  • 443   HTTPS (frontend dashboard + crypto-bot API)              │
│  • 5678  n8n dashboard (basic auth + IP whitelist)                │
└──────────────────────────────────────────────────────────────────┘
```

### 5.2 Resource Allocation Target (Cloud VPS 30 NVMe, 12 GB RAM)

| Container | RAM target | CPU share |
|---|---|---|
| axiom_db (Postgres+Timescale) | 3 GB | 1 vCPU |
| axiom_redis | 512 MB | 0.25 vCPU |
| axiom_pgbouncer | 64 MB | 0.05 vCPU |
| axiom_n8n | 512 MB | 0.25 vCPU |
| axiom_brain | 1 GB | 0.5 vCPU |
| axiom_pattern | 1.5 GB | 0.75 vCPU (untuk numpy/pandas/sklearn) |
| axiom_consensus | 512 MB (idle most of time, only weekly burst) | 0.25 vCPU |
| axiom_bridge + thanatos + telegram | 256 MB each (~768 MB total) | 0.15 vCPU each (~0.45) |
| cryptobot_main | 1.5 GB | 0.75 vCPU |
| cryptobot_param_sync | 256 MB | 0.1 vCPU |
| axiom_nginx | 128 MB | 0.05 vCPU |
| **Total** | **~10 GB** | **~4 vCPU** |
| **Headroom** | 2 GB | 0 vCPU (peak burst boleh > capacity, OS akan throttle) |

> Jika VPS hanya VPS 20 NVMe (8 GB), turunkan: `axiom_pattern` → 800 MB (delay TF/transformer), `axiom_db` → 2 GB. Akan jalan tapi pattern recognition lebih lambat.

### 5.3 Persistence Strategy

| Path di VPS | Volume Docker | Backup |
|---|---|---|
| `/root/axiom_core/data/postgres_data` | `axiom_db` data | Daily `pg_dump` ke `/root/axiom_backups/`, mingguan upload ke Backblaze B2 |
| `/root/axiom_core/data/redis_data` | `axiom_redis` AOF | Daily snapshot ke `/root/axiom_backups/redis/` |
| `/root/axiom_core/data/n8n_data` | `axiom_n8n` workflows | Weekly export workflow JSON ke git repo `axiom_core` (committed) |
| `/root/axiom_core/logs` | semua service logs | Rotated, retention 30 hari, kemudian gzip+archive |
| `/root/axiom_core/agents/crypto_bot` | submodule | git remote = backup natural |

→ Detail backup: **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md#backup--rollback-plan)**.

---

## 6. SECURITY ARCHITECTURE

### 6.1 Defense Layers

1. **Network**: UFW firewall, hanya port wajib terbuka
2. **Reverse proxy**: nginx dengan rate limiting (10 req/s per IP) + Let's Encrypt TLS
3. **App auth**:
   - Crypto-bot Telegram: PIN auth dengan TTL 4 jam
   - Crypto-bot dashboard: PIN login → JWT session
   - Axiom Telegram: hardcoded `aru_id` whitelist
   - n8n: basic auth via env (`N8N_BASIC_AUTH_USER` + password panjang)
   - Postgres: per-user GRANT terbatas
   - Redis: requirepass (set lewat `REDIS_PASSWORD` env)
4. **Secret management**:
   - File `.env` chmod 600, owner root only
   - **Tidak pernah commit `.env`** — `.gitignore` strict
   - API keys (Bybit, Anthropic, OpenRouter) di-rotate quarterly
   - Bybit API key minimum permission (read + trade, **TIDAK** withdraw)
5. **Audit**: semua perubahan parameter & kode tercatat di `code_change_audit` & `parameter_versions` tables — tidak bisa di-bypass
6. **Sanitization**: log_sanitizer.py menyaring API keys/tokens dari log output sebelum tulis ke file

### 6.2 Threat Model & Mitigasi

| Threat | Mitigasi |
|---|---|
| Bybit API key bocor → unauthorized trade | API key minimum scope (no withdraw); IP whitelist di Bybit dashboard ke IP VPS |
| Telegram bot di-spam attacker | Rate limit di handler + reject non-whitelisted user_id |
| Postgres SQL injection | Pakai parametrized query (psycopg2 placeholder, jangan f-string) |
| n8n workflow XSS via webhook | Disable n8n public webhooks tanpa auth header |
| Container escape | Run as non-root user di Dockerfile (UID 1000), no privileged mode |
| Aru kehilangan akses VPS | Backup SSH key di password manager + fallback root login dari Contabo console |
| Axiom auto-patch flaw merusak strategi | R5 patch proposal workflow + auto-rollback 24 jam |
| Drawdown kabur ke >50% sebelum manual stop | Circuit breaker hard-coded 15% di crypto-bot's circuit_breaker.py + Telegram alert |

---

## 7. SCALABILITY PATH

| Stage | Capital ($) | Pairs aktif | RAM total | VPS recommendation |
|---|---|---|---|---|
| Seed | 50–299 | 1–2 (BTC, ETH) | 8 GB | VPS 20 NVMe (cukup) |
| Growth | 300–699 | 3 (+SOL) | 10 GB | VPS 30 NVMe ⭐ |
| Pro | 700–1499 | 4–5 (+BNB, AVAX) | 12 GB | VPS 30 NVMe |
| Elite | 1500+ | 6–8 (full set) | 14+ GB | VPS 40 NVMe atau VDS |
| Multi-asset (jangka panjang) | 5000+ | 10+ pairs + futures | 24+ GB | Multi-VPS dengan database read-replica + load balancer |

**Bottleneck yang mungkin muncul saat scale-up:**
- LLM API rate limit (Anthropic) — solusi: tier upgrade + fallback ke OpenRouter Hermes
- Postgres write throughput saat banyak trade — solusi: TimescaleDB compression + connection pooling
- Bybit API rate limit — solusi: WebSocket subscribe (sudah di pybit) menggantikan REST polling

---

## 8. EVOLUTION PRINCIPLES

1. **Backward compatibility**: schema migration wajib pakai Alembic (untuk crypto-bot DB) atau script `migrations/{N}_*.sql` (axiom). Drop column hanya setelah 2 release transition
2. **Feature flag**: setiap kapabilitas baru axiom (terutama Layer 3/4) di-gate via env var `FEATURE_X_ENABLED=false` default; flip ke true setelah validasi
3. **Observability first**: tambah metric/log dulu, baru tambah feature. Tidak boleh deploy feature tanpa monitoring
4. **Safety hatches**: setiap auto-action axiom punya kill switch (Redis flag `axiom:auto_disabled=1`) yang disable semua perubahan otomatis
5. **Single tenancy assumed**: sistem ini designed untuk 1 user (Aru). Multi-tenant bukan goal — jika berubah, butuh rewrite besar di auth layer

---

## CURRENT STATE

**Last sync:** 2026-04-27

- ✅ Topology desain final ter-dokumentasi (11 container, axiom-network)
- ✅ Database stack final: Postgres 16 + TimescaleDB + PgBouncer + Redis 7
- ✅ Communication channels mapped (Redis BLPOP, pub/sub, listen/notify, REST, git commit)
- ✅ Resource allocation target untuk VPS 30 NVMe (12 GB RAM)
- ✅ Security layers documented
- ⏳ Container `axiom_pattern` & `axiom_consensus` & `cryptobot_param_sync`: **belum dibangun**, akan jadi output Phase 3
- ⏳ Resource limits di docker-compose: belum applied di compose existing — wajib update
- ⏳ Postgres user/role per service: belum dibuat — wajib jadi DDL di `init.sql`
- ⏳ nginx reverse proxy + Let's Encrypt: belum di-setup, masuk Phase 2
- ⏳ Submodule `agents/crypto_bot/`: existing axiom ZIP punya stub `bot.py` yang harus diganti dengan submodule asli (lihat **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md#submodule-replacement)**)

---

## NEXT ACTION

**Untuk Claude Code:**

1. Saat membaca ini dan menemukan file/container yang belum ada di repo nyata → **JANGAN auto-create**. Update CURRENT STATE → flag missing → tunggu instruksi Aru.

2. Update `docker-compose.yaml` di root agar menambahkan service:
   - `axiom_pattern` (new, akan dibangun di Phase 3)
   - `axiom_consensus` (new, akan dibangun di Phase 3)
   - `cryptobot_main` (build context = `agents/crypto_bot/`)
   - `cryptobot_param_sync` (build context = `agents/crypto_bot/`, command = `python -m axiom_sync.parameter_sync`)
   - `axiom_pgbouncer`
   - `axiom_nginx`
   - Ganti `db: postgres:14-alpine` → `db: timescale/timescaledb:latest-pg16`
   - Tambah resource `mem_limit` & `cpus` per service sesuai tabel 5.2
   - Pertahankan service existing (db, redis, n8n, axiom-brain, axiom-bridge, axiom-thanatos, axiom-telegram)
   - Tambah `axiom_executioner` → **HAPUS** (legacy executioner, sudah deprecated per keputusan B di Konflik 1)

3. Setelah update `docker-compose.yaml`, **commit dengan pesan**: `[infra] update compose for VPS 30 topology + 4 new services + Timescale upgrade`

4. Update `## CURRENT STATE` di file ini untuk centang item yang sudah selesai.

→ Lanjut ke **[INTEGRATION_GUIDE.md](./INTEGRATION_GUIDE.md)** untuk mempelajari kontrak antar komponen sebelum mulai coding.
