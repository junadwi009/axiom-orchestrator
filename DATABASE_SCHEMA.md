# DATABASE_SCHEMA.md — SCHEMA LENGKAP & STRATEGY INDEX

> **Status:** AUTHORITATIVE | **Owner:** Aru (aru009)
> Setiap perubahan schema **wajib** lewat migration script + update file ini.
> Tidak boleh ada `ALTER TABLE` ad-hoc tanpa migration.

→ Prerequisite: **[ARCHITECTURE.md](./ARCHITECTURE.md)** & **[INTEGRATION_GUIDE.md](./INTEGRATION_GUIDE.md)** sudah dibaca.

---

## 1. STACK & VERSI

| Komponen | Versi target |
|---|---|
| PostgreSQL | 16.x (latest stable) |
| TimescaleDB | 2.16+ (community edition) |
| PgBouncer | 1.21+ (transaction pooling) |
| Redis | 7-alpine (dengan AOF persistence) |
| psycopg2-binary | 2.9.9+ (axiom) |
| asyncpg | 0.29+ (untuk crypto-bot setelah migrasi dari supabase-py) |

Image Docker: `timescale/timescaledb:latest-pg16`

---

## 2. STRUKTUR DATABASE

Satu Postgres instance, **dua database terpisah** untuk isolasi domain:

```
PostgreSQL 16
├── DB: axiom_memories       (axiom owns)
└── DB: cryptobot_db         (crypto-bot owns, axiom read-only)
```

→ Ini implementasi keputusan Konflik #2 = ii (konsolidasi self-hosted, satu DB cluster, dua database).

---

## 3. DATABASE: `axiom_memories` (AXIOM-OWNED)

### 3.1 Tabel Existing (dari `init.sql` v2 axiom — DIPERTAHANKAN)

#### `knowledge_base`
Penyimpanan persona/protocol agen Hermes Council.

```sql
CREATE TABLE IF NOT EXISTS knowledge_base (
    id               SERIAL PRIMARY KEY,
    entity_source    VARCHAR(20)  NOT NULL,
    pattern_name     VARCHAR(100) NOT NULL,
    protocol_content TEXT,
    pattern_data     JSONB,
    logic_summary    TEXT,
    confidence_score DECIMAL(5, 2) DEFAULT 100.0,
    file_path        VARCHAR(255),
    last_synced      TIMESTAMPTZ DEFAULT now(),
    created_at       TIMESTAMPTZ DEFAULT now(),
    CONSTRAINT uq_kb_source_pattern UNIQUE (entity_source, pattern_name)
);
CREATE INDEX idx_kb_entity  ON knowledge_base(entity_source);
CREATE INDEX idx_kb_pattern ON knowledge_base(pattern_name);
```

#### `kai_ledger`
Audit harian dari Kai (CFO agent).

```sql
CREATE TABLE IF NOT EXISTS kai_ledger (
    id                      SERIAL PRIMARY KEY,
    day_count               INT UNIQUE,
    actual_balance          DECIMAL(20, 2),
    expected_balance        DECIMAL(20, 2),
    deficit_surplus         DECIMAL(20, 2),
    opex_cost               DECIMAL(15, 4) DEFAULT 0,
    is_compounding_on_track BOOLEAN,
    audit_log               TEXT,
    created_at              TIMESTAMPTZ DEFAULT now()
);
```

#### `ares_market_scans` → konversi ke **HYPERTABLE** (TimescaleDB)
Snapshot pasar dari Ares analyzer setiap cycle.

```sql
CREATE TABLE IF NOT EXISTS ares_market_scans (
    id                 BIGSERIAL,
    symbol             VARCHAR(20)   NOT NULL,
    current_price      DECIMAL(20, 10),
    volatility_spread  DECIMAL(20, 10),
    liquidity_gap      DECIMAL(20, 10),
    best_bid           DECIMAL(20, 10),
    best_ask           DECIMAL(20, 10),
    rsi_14h            DECIMAL(8, 4),
    volume_24h_usd     DECIMAL(20, 4),
    raw_ohlcv_snapshot JSONB,
    real_intel         JSONB,
    scan_timestamp     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (scan_timestamp, symbol, id)
);

-- Konversi jadi hypertable, partition per 1 hari
SELECT create_hypertable('ares_market_scans', 'scan_timestamp',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE);

CREATE INDEX idx_ares_sym_time ON ares_market_scans(symbol, scan_timestamp DESC);

-- Compression policy: kompres chunk umur >7 hari
ALTER TABLE ares_market_scans SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'symbol'
);
SELECT add_compression_policy('ares_market_scans', INTERVAL '7 days');

-- Retention: drop chunk umur >180 hari
SELECT add_retention_policy('ares_market_scans', INTERVAL '180 days');

-- Continuous aggregate: ringkasan harian per symbol
CREATE MATERIALIZED VIEW ares_market_scans_daily
WITH (timescaledb.continuous) AS
SELECT
    symbol,
    time_bucket('1 day', scan_timestamp) AS day,
    AVG(current_price)         AS avg_price,
    MIN(current_price)         AS min_price,
    MAX(current_price)         AS max_price,
    AVG(volatility_spread)     AS avg_spread,
    AVG(liquidity_gap)         AS avg_slippage,
    AVG(rsi_14h)               AS avg_rsi,
    SUM(volume_24h_usd)        AS sum_volume_24h,
    COUNT(*)                   AS scan_count
FROM ares_market_scans
GROUP BY symbol, day
WITH NO DATA;

SELECT add_continuous_aggregate_policy('ares_market_scans_daily',
    start_offset => INTERVAL '7 days',
    end_offset => INTERVAL '1 hour',
    schedule_interval => INTERVAL '5 minutes');
```

### 3.2 Tabel BARU untuk Observability & Self-Improvement

#### `axiom_evaluations` → HYPERTABLE
Hasil evaluasi axiom terhadap keputusan crypto-bot.

```sql
CREATE TABLE IF NOT EXISTS axiom_evaluations (
    id                  BIGSERIAL,
    evaluated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    evaluation_type     VARCHAR(30) NOT NULL,  -- 'trade_review', 'strategy_review', 'weekly_consensus'
    target_entity       VARCHAR(50),           -- 'trade:uuid' / 'pair:BTC/USDT' / 'period:2026-W17'
    evaluator           VARCHAR(30) NOT NULL,  -- 'hermes_council' / 'pattern_layer1' / 'pattern_layer2' / 'rl_layer3'
    verdict             VARCHAR(20),           -- 'optimal' / 'suboptimal' / 'concerning' / 'critical'
    confidence_score    DECIMAL(4, 3),
    findings            JSONB NOT NULL,        -- detail observasi
    recommended_action  TEXT,
    proposal_id         UUID,                  -- FK ke axiom_proposals (nullable)
    PRIMARY KEY (evaluated_at, id)
);

SELECT create_hypertable('axiom_evaluations', 'evaluated_at',
    chunk_time_interval => INTERVAL '7 days', if_not_exists => TRUE);

CREATE INDEX idx_axeval_target ON axiom_evaluations(target_entity, evaluated_at DESC);
CREATE INDEX idx_axeval_type   ON axiom_evaluations(evaluation_type, evaluated_at DESC);
```

#### `consensus_log`
Log perbandingan output Opus (di crypto-bot) vs Hermes Council (di axiom).

```sql
CREATE TABLE IF NOT EXISTS consensus_log (
    id                       SERIAL PRIMARY KEY,
    consensus_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    period_start             DATE NOT NULL,
    period_end               DATE NOT NULL,
    opus_summary             TEXT,
    opus_recommendations     JSONB,           -- {"strategy_params_changes": {...}, "pair_changes": {...}}
    hermes_summary           TEXT,
    hermes_recommendations   JSONB,
    agreement_level          VARCHAR(20),     -- 'unanimous' / 'majority' / 'split' / 'opposing'
    final_decision           VARCHAR(20),     -- 'apply_opus' / 'apply_hermes' / 'apply_consensus' / 'tiebreaker_required' / 'hold'
    tiebreaker_used          VARCHAR(30),     -- nullable: 'sonnet_4_6' jika tiebreak
    tiebreaker_output        TEXT,
    proposal_ids_generated   UUID[],          -- list FK ke axiom_proposals
    cost_breakdown           JSONB,           -- {"opus_usd": 0.45, "hermes_usd": 0.02, "tiebreak_usd": 0.08}
    raw_opus_response        TEXT,
    raw_hermes_chat_history  JSONB
);

CREATE INDEX idx_consensus_period ON consensus_log(period_start DESC);
```

#### `parameter_versions`
Audit trail setiap perubahan parameter — siapapun yang melakukan.

```sql
CREATE TABLE IF NOT EXISTS parameter_versions (
    id              SERIAL PRIMARY KEY,
    target_table    VARCHAR(50) NOT NULL,    -- 'strategy_params' / 'pair_config'
    target_pk       VARCHAR(100) NOT NULL,   -- 'pair=BTC/USDT' / 'pair=ETH/USDT'
    version_number  INT NOT NULL,            -- monotonic per (table, pk)
    snapshot_before JSONB NOT NULL,
    snapshot_after  JSONB NOT NULL,
    diff            JSONB NOT NULL,          -- {"rsi_oversold": {"old": 32, "new": 28}}
    changed_by      VARCHAR(50) NOT NULL,    -- 'aru_manual' / 'parameter_sync:proposal_uuid' / 'opus_brain'
    proposal_id     UUID,                    -- FK ke axiom_proposals (nullable)
    reason          TEXT,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_param_version UNIQUE (target_table, target_pk, version_number)
);

CREATE INDEX idx_param_target ON parameter_versions(target_table, target_pk, version_number DESC);
CREATE INDEX idx_param_time   ON parameter_versions(changed_at DESC);
```

#### `pattern_discoveries`
Pola yang ditemukan oleh axiom-pattern (Layer 1 ML).

```sql
CREATE TABLE IF NOT EXISTS pattern_discoveries (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    discovered_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    discovered_by            VARCHAR(30) NOT NULL,  -- 'pattern_layer1' / 'pattern_layer2_anomaly' / 'pattern_layer2_regime' / 'crossexch_layer'
    pattern_type             VARCHAR(50) NOT NULL,  -- 'iceberg_at_resistance' / 'volume_climax' / 'regime_chaos_onset' / 'cross_exch_arbitrage' / dll
    pair                     VARCHAR(20),           -- nullable kalau pola universal
    evidence_window_start    TIMESTAMPTZ NOT NULL,
    evidence_window_end      TIMESTAMPTZ NOT NULL,
    occurrences              INT NOT NULL,
    precision_score          DECIMAL(4, 3),
    recall_score             DECIMAL(4, 3),
    expected_outcome         TEXT,
    expected_horizon_minutes INT,
    pattern_signature        JSONB NOT NULL,        -- features yang membedakan pattern ini
    sample_event_ids         UUID[],                -- referensi ke trades / bot_events yang memicu deteksi
    status                   VARCHAR(20) DEFAULT 'candidate',
                                                    -- 'candidate' / 'validated' / 'promoted_to_rule' / 'rejected'
    promoted_to_proposal_id  UUID,                  -- FK ke axiom_proposals saat dipromosikan
    notes                    TEXT
);

CREATE INDEX idx_pattern_type   ON pattern_discoveries(pattern_type);
CREATE INDEX idx_pattern_pair   ON pattern_discoveries(pair);
CREATE INDEX idx_pattern_status ON pattern_discoveries(status);
CREATE INDEX idx_pattern_disc   ON pattern_discoveries(discovered_at DESC);
```

#### `intervention_log`
Log setiap kali axiom mengintervensi crypto-bot lewat Channel A/B/C (lihat **[INTEGRATION_GUIDE.md](./INTEGRATION_GUIDE.md#mekanisme-intervensi-axiom)**).

```sql
CREATE TABLE IF NOT EXISTS intervention_log (
    id                  SERIAL PRIMARY KEY,
    intervened_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    channel             VARCHAR(1) NOT NULL CHECK (channel IN ('A','B','C')),
                                                    -- A: Redis flag, B: param rewrite, C: code change
    action_type         VARCHAR(30) NOT NULL,       -- 'pause' / 'override' / 'param_change' / 'code_patch'
    target              VARCHAR(100),               -- 'global' / 'pair=BTC/USDT' / file path
    payload             JSONB NOT NULL,
    triggered_by        VARCHAR(50) NOT NULL,       -- 'hermes_council' / 'pattern_layer2_chaos' / 'aru_manual'
    initiated_by_id     UUID,                       -- proposal_id atau pattern_id penyebab
    outcome             VARCHAR(20),                -- 'success' / 'failed' / 'rolled_back'
    outcome_at          TIMESTAMPTZ,
    outcome_notes       TEXT
);

CREATE INDEX idx_interv_channel ON intervention_log(channel, intervened_at DESC);
CREATE INDEX idx_interv_target  ON intervention_log(target);
```

#### `code_change_audit`
Audit trail untuk Channel C (code rewrite).

```sql
CREATE TABLE IF NOT EXISTS code_change_audit (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    proposed_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    change_type         VARCHAR(30) NOT NULL,   -- 'rule_addition' / 'rule_removal' / 'param_logic_update' / 'prompt_update'
    target_file         VARCHAR(255) NOT NULL,
    diff_unified        TEXT NOT NULL,
    reason              TEXT NOT NULL,
    proposed_by         VARCHAR(50) NOT NULL,   -- 'hermes_council' / 'pattern_layer4_self_modify'
    backtest_summary    JSONB,                  -- sharpe before/after, max_dd before/after
    validation_logs     TEXT,                   -- pylint output, pytest output, backtest output
    asura_review        TEXT,                   -- safety check log
    status              VARCHAR(20) NOT NULL DEFAULT 'proposed',
                                                -- proposed -> validated -> safety_passed -> approved -> committed -> applied -> rolled_back
    approved_by         VARCHAR(50),            -- 'aru' atau 'auto'
    approved_at         TIMESTAMPTZ,
    branch_name         VARCHAR(100),
    git_commit_sha      VARCHAR(40),
    applied_at          TIMESTAMPTZ,
    rolled_back_at      TIMESTAMPTZ,
    rollback_reason     TEXT,
    rollback_pnl_delta  DECIMAL(15, 4)         -- selisih PnL dari baseline saat rollback
);

CREATE INDEX idx_codechg_status ON code_change_audit(status);
CREATE INDEX idx_codechg_file   ON code_change_audit(target_file);
CREATE INDEX idx_codechg_time   ON code_change_audit(proposed_at DESC);
```

#### `axiom_proposals`
Pipeline proposal untuk Channel B (parameter rewrite).

```sql
CREATE TABLE IF NOT EXISTS axiom_proposals (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    proposal_type   VARCHAR(20) NOT NULL,       -- 'parameter' / 'prompt' / 'pair_config'
    target_table    VARCHAR(50) NOT NULL,
    target_pk       VARCHAR(100) NOT NULL,
    diff            JSONB NOT NULL,
    reason          TEXT NOT NULL,
    backtest_result JSONB,
    status          VARCHAR(20) NOT NULL DEFAULT 'proposed',
                                                 -- proposed -> validated -> approved -> applied -> rolled_back / rejected / failed
    created_by      VARCHAR(50) NOT NULL,
    approved_by     VARCHAR(50),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    validated_at    TIMESTAMPTZ,
    approved_at     TIMESTAMPTZ,
    applied_at      TIMESTAMPTZ,
    rolled_back_at  TIMESTAMPTZ,
    rollback_reason TEXT
);

CREATE INDEX idx_proposal_status ON axiom_proposals(status, created_at);
CREATE INDEX idx_proposal_target ON axiom_proposals(target_table, target_pk);
```

#### `cross_exchange_signals` → HYPERTABLE
Hasil scan multi-exchange via ccxt (Bybit + Binance + OKX + Bitget).

```sql
CREATE TABLE IF NOT EXISTS cross_exchange_signals (
    id              BIGSERIAL,
    scanned_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    pair            VARCHAR(20) NOT NULL,
    exchange_prices JSONB NOT NULL,             -- {"bybit": 95234.5, "binance": 95228.0, "okx": 95231.2}
    max_spread_bps  INT,                        -- selisih harga tertinggi dalam basis points
    funding_rates   JSONB,                      -- {"bybit": 0.0001, "binance": 0.00008}
    volume_24h      JSONB,
    arbitrage_opp   BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (scanned_at, pair, id)
);

SELECT create_hypertable('cross_exchange_signals', 'scanned_at',
    chunk_time_interval => INTERVAL '1 day', if_not_exists => TRUE);

CREATE INDEX idx_crossexch_pair ON cross_exchange_signals(pair, scanned_at DESC);
CREATE INDEX idx_crossexch_arb  ON cross_exchange_signals(arbitrage_opp) WHERE arbitrage_opp = TRUE;

-- Compression
ALTER TABLE cross_exchange_signals SET (timescaledb.compress, timescaledb.compress_segmentby='pair');
SELECT add_compression_policy('cross_exchange_signals', INTERVAL '7 days');
SELECT add_retention_policy('cross_exchange_signals', INTERVAL '90 days');
```

---

## 4. DATABASE: `cryptobot_db` (CRYPTO-BOT-OWNED, dari Supabase)

Schema ini **diport dari** `agents/crypto_bot/database/schema.sql` (12 tabel) dengan **tambahan TimescaleDB extension** untuk tabel time-heavy.

### 4.1 Tabel yang Tetap Sama (port langsung)
- `pair_config` (PK varchar primary key, low write rate) — biasa
- `strategy_params` (low row count, ~10 row max) — biasa
- `news_weights` — biasa

### 4.2 Tabel yang Dikonversi ke HYPERTABLE

#### `trades` → HYPERTABLE
```sql
CREATE TABLE trades (
    id              uuid DEFAULT uuid_generate_v4(),
    pair            varchar(20) NOT NULL,
    side            varchar(4)  NOT NULL CHECK (side IN ('buy','sell')),
    amount_usd      numeric(12,4),
    entry_price     numeric(18,8),
    exit_price      numeric(18,8),
    pnl_usd         numeric(12,4),
    fee_usd         numeric(10,4) DEFAULT 0,
    status          varchar(10) NOT NULL DEFAULT 'open' CHECK (status IN ('open','closed','cancelled')),
    trigger_source  varchar(20),
    bybit_order_id  varchar(50),
    is_paper        boolean NOT NULL DEFAULT false,
    opened_at       timestamptz NOT NULL DEFAULT now(),
    closed_at       timestamptz,
    PRIMARY KEY (opened_at, id)
);

SELECT create_hypertable('trades', 'opened_at',
    chunk_time_interval => INTERVAL '30 days', if_not_exists => TRUE);

CREATE INDEX idx_trades_pair      ON trades(pair, opened_at DESC);
CREATE INDEX idx_trades_status    ON trades(status, opened_at DESC);
CREATE INDEX idx_trades_is_paper  ON trades(is_paper, opened_at DESC);

-- Tidak compress — trades aktif (status='open') butuh fast UPDATE
-- Setelah closed_at + 30 hari, baru kompres
ALTER TABLE trades SET (timescaledb.compress, timescaledb.compress_segmentby='pair');
SELECT add_compression_policy('trades', INTERVAL '30 days');
```

#### `bot_events` → HYPERTABLE
```sql
CREATE TABLE bot_events (
    id           uuid DEFAULT uuid_generate_v4(),
    event_type   varchar(50) NOT NULL,
    severity     varchar(10) NOT NULL DEFAULT 'info' CHECK (severity IN ('debug','info','warn','error','critical')),
    payload      jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (created_at, id)
);

SELECT create_hypertable('bot_events', 'created_at',
    chunk_time_interval => INTERVAL '7 days', if_not_exists => TRUE);

CREATE INDEX idx_events_type     ON bot_events(event_type, created_at DESC);
CREATE INDEX idx_events_severity ON bot_events(severity, created_at DESC);

ALTER TABLE bot_events SET (timescaledb.compress);
SELECT add_compression_policy('bot_events', INTERVAL '14 days');
SELECT add_retention_policy('bot_events', INTERVAL '365 days');
```

#### `news_items` → HYPERTABLE
```sql
CREATE TABLE news_items (
    id                uuid DEFAULT uuid_generate_v4(),
    headline          text NOT NULL,
    source            varchar(50),
    url               text,
    pairs_mentioned   varchar(20)[],
    haiku_sentiment   numeric(4,3),
    haiku_urgency     numeric(4,3),
    haiku_relevance   numeric(4,3),
    sanitized         boolean DEFAULT false,
    published_at      timestamptz NOT NULL,
    fetched_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (published_at, id)
);

SELECT create_hypertable('news_items', 'published_at',
    chunk_time_interval => INTERVAL '30 days', if_not_exists => TRUE);

CREATE INDEX idx_news_pairs     ON news_items USING gin(pairs_mentioned);
CREATE INDEX idx_news_relevance ON news_items(haiku_relevance DESC, published_at DESC);

ALTER TABLE news_items SET (timescaledb.compress);
SELECT add_compression_policy('news_items', INTERVAL '30 days');
SELECT add_retention_policy('news_items', INTERVAL '180 days');
```

#### `claude_usage` → HYPERTABLE
```sql
CREATE TABLE claude_usage (
    id              uuid DEFAULT uuid_generate_v4(),
    model           varchar(20) NOT NULL,
    calls           int NOT NULL DEFAULT 1,
    input_tokens    int NOT NULL DEFAULT 0,
    output_tokens   int NOT NULL DEFAULT 0,
    cost_usd        numeric(10, 6) NOT NULL DEFAULT 0,
    purpose         varchar(50),
    usage_date      date NOT NULL DEFAULT current_date,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (created_at, id)
);

SELECT create_hypertable('claude_usage', 'created_at',
    chunk_time_interval => INTERVAL '30 days', if_not_exists => TRUE);

CREATE INDEX idx_claude_date  ON claude_usage(usage_date DESC);
CREATE INDEX idx_claude_model ON claude_usage(model, created_at DESC);
```

### 4.3 Tabel Sisanya (port standar)
- `portfolio_state` — daily snapshot, biasa
- `opus_memory` — weekly, biasa
- `infra_fund` — biasa
- `tier_history` — biasa
- `backtest_results` — biasa

---

## 5. ACCESS CONTROL

### 5.1 User & Role

```sql
-- File: init.sql (di-eksekusi saat container db pertama kali start)

-- USER untuk axiom services
CREATE USER axiom_user WITH PASSWORD :'AXIOM_PASSWORD';

-- USER untuk crypto-bot
CREATE USER cryptobot_user WITH PASSWORD :'CRYPTOBOT_PASSWORD';

-- USER read-only untuk axiom yang observe crypto-bot
CREATE USER readonly_observer WITH PASSWORD :'OBSERVER_PASSWORD';

-- USER untuk parameter_sync worker (write ke cryptobot_db.strategy_params)
CREATE USER parameter_sync_user WITH PASSWORD :'PARAMSYNC_PASSWORD';

-- USER untuk n8n
CREATE USER n8n_user WITH PASSWORD :'N8N_PASSWORD';
```

### 5.2 GRANT Statements

```sql
-- Connect & schema
\c axiom_memories
GRANT CONNECT ON DATABASE axiom_memories TO axiom_user, readonly_observer;
GRANT USAGE ON SCHEMA public TO axiom_user, readonly_observer;

-- axiom_user: full pada axiom_memories
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO axiom_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO axiom_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO axiom_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO axiom_user;

\c cryptobot_db
GRANT CONNECT ON DATABASE cryptobot_db TO cryptobot_user, axiom_user, readonly_observer, parameter_sync_user;
GRANT USAGE ON SCHEMA public TO cryptobot_user, axiom_user, readonly_observer, parameter_sync_user;

-- cryptobot_user: full pada cryptobot_db
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO cryptobot_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO cryptobot_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO cryptobot_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO cryptobot_user;

-- readonly_observer: hanya SELECT pada cryptobot_db
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_observer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly_observer;

-- parameter_sync_user: SELECT pada semua tabel + UPDATE pada strategy_params, pair_config
GRANT SELECT ON ALL TABLES IN SCHEMA public TO parameter_sync_user;
GRANT UPDATE ON strategy_params, pair_config TO parameter_sync_user;
GRANT INSERT ON parameter_versions TO parameter_sync_user;  -- jika ada di cryptobot_db (sebenarnya di axiom_memories)
GRANT EXECUTE ON FUNCTION pg_notify(text, text) TO parameter_sync_user;

-- n8n_user: full pada cryptobot_db (karena n8n bisa write ke berbagai tabel sesuai workflow)
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO n8n_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO n8n_user;
```

### 5.3 Connection Pooling via PgBouncer

PgBouncer config (`pgbouncer.ini`):

```ini
[databases]
axiom_memories = host=axiom_db port=5432 dbname=axiom_memories
cryptobot_db   = host=axiom_db port=5432 dbname=cryptobot_db

[pgbouncer]
listen_port = 6432
listen_addr = 0.0.0.0
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 200
default_pool_size = 25
reserve_pool_size = 5
reserve_pool_timeout = 5
server_idle_timeout = 600
log_connections = 0
log_disconnections = 0
```

Service di docker-compose connect ke `axiom_pgbouncer:6432` (bukan ke `axiom_db:5432` langsung).

---

## 6. INDEX STRATEGY UNTUK QUERY CEPAT

### 6.1 Hot Query Patterns

| Query | Frekuensi | Index yang dipakai |
|---|---|---|
| `SELECT * FROM trades WHERE status='open'` | tiap cycle (30s) | `idx_trades_status` |
| `SELECT * FROM trades WHERE pair=$1 ORDER BY opened_at DESC LIMIT 50` | per signal generation | `idx_trades_pair` |
| `SELECT * FROM ares_market_scans WHERE symbol=$1 ORDER BY scan_timestamp DESC LIMIT 14` | per signal cycle | `idx_ares_sym_time` |
| `SELECT count(*) FROM claude_usage WHERE model='haiku' AND usage_date=current_date` | tiap call Haiku | `idx_claude_date` + `idx_claude_model` |
| `SELECT * FROM news_items WHERE pairs_mentioned @> ARRAY[$1] ORDER BY published_at DESC LIMIT 3` | per Sonnet call | `idx_news_pairs` (GIN) |
| `SELECT * FROM bot_events WHERE event_type=$1 AND created_at > now()-INTERVAL '1 hour'` | setiap minute by axiom | `idx_events_type` |
| `SELECT * FROM pattern_discoveries WHERE status='candidate' ORDER BY discovered_at DESC` | per axiom-pattern cycle | `idx_pattern_status` |
| `SELECT * FROM axiom_proposals WHERE status='approved' ORDER BY created_at LIMIT 5` | per parameter_sync cycle | `idx_proposal_status` |

### 6.2 Larangan Index

❌ **Jangan buat index** pada kolom yang **selalu di-UPDATE** (mis. `trades.exit_price`, `trades.pnl_usd`) — write amplification besar.

❌ **Jangan over-index** — setiap index = overhead pada INSERT. Maksimum 5 index per tabel hot-write seperti `trades`, `ares_market_scans`.

✅ Pakai partial index untuk filter umum:
```sql
CREATE INDEX idx_trades_open ON trades(pair, opened_at DESC) WHERE status='open';
```

---

## 7. MIGRATION DARI SUPABASE

### 7.1 Workflow

```bash
# 1. Dump schema dari Supabase (cryptobot_db existing)
pg_dump -h db.{ref}.supabase.co -U postgres -p 5432 \
  --schema-only --no-owner --no-acl \
  -f /tmp/supabase_schema.sql crypto_bot

# 2. Dump data
pg_dump -h db.{ref}.supabase.co -U postgres -p 5432 \
  --data-only --no-owner --column-inserts \
  -f /tmp/supabase_data.sql crypto_bot

# 3. Apply ke local Postgres
psql -h localhost -p 5432 -U cryptobot_user -d cryptobot_db -f /tmp/supabase_schema.sql

# 4. Convert tabel time-heavy ke hypertable (run script ini SETELAH schema apply, SEBELUM data load)
psql -h localhost -p 5432 -U cryptobot_user -d cryptobot_db <<EOF
SELECT create_hypertable('trades', 'opened_at', migrate_data => TRUE, if_not_exists => TRUE);
SELECT create_hypertable('bot_events', 'created_at', migrate_data => TRUE, if_not_exists => TRUE);
SELECT create_hypertable('news_items', 'published_at', migrate_data => TRUE, if_not_exists => TRUE);
SELECT create_hypertable('claude_usage', 'created_at', migrate_data => TRUE, if_not_exists => TRUE);
EOF

# 5. Load data
psql -h localhost -p 5432 -U cryptobot_user -d cryptobot_db -f /tmp/supabase_data.sql

# 6. Validate row counts match
psql -h localhost -p 5432 -U cryptobot_user -d cryptobot_db -c \
  "SELECT 'trades' AS table_name, count(*) FROM trades
   UNION ALL SELECT 'bot_events', count(*) FROM bot_events
   UNION ALL SELECT 'news_items', count(*) FROM news_items
   UNION ALL SELECT 'opus_memory', count(*) FROM opus_memory;"

# Compare dengan output Supabase, harus identik
```

### 7.2 Code Change di Crypto-bot

`agents/crypto_bot/database/client.py` perlu di-rewrite dari `supabase-py` → `asyncpg`:

```python
# BEFORE (supabase-py)
from supabase import create_client
self._client = create_client(SUPABASE_URL, SUPABASE_SERVICE_KEY)
res = self._client.table("trades").select("*").eq("status", "open").execute()

# AFTER (asyncpg)
import asyncpg
self._pool = await asyncpg.create_pool(
    host=settings.DB_HOST, port=settings.DB_PORT,
    user=settings.DB_USER_CRYPTOBOT, password=settings.DB_PASSWORD_CRYPTOBOT,
    database=settings.DB_NAME_CRYPTOBOT,
    min_size=2, max_size=10
)
async with self._pool.acquire() as conn:
    rows = await conn.fetch("SELECT * FROM trades WHERE status=$1", "open")
```

→ Ini perubahan substantial. Detail step-by-step di **[MIGRATION_GUIDE.md](./MIGRATION_GUIDE.md#code-migration-supabase--asyncpg)**.

---

## 8. BACKUP & DISASTER RECOVERY

### 8.1 Daily Logical Backup

Cron di host VPS (`crontab -e`):

```bash
# Daily 03:00 WIB - dump kedua database
0 3 * * * /root/axiom_core/scripts/backup_postgres.sh
```

`scripts/backup_postgres.sh`:

```bash
#!/bin/bash
set -euo pipefail
BACKUP_DIR=/root/axiom_backups/postgres
DATE=$(date +%Y%m%d-%H%M%S)
mkdir -p $BACKUP_DIR

# Dump axiom_memories
docker exec axiom_db pg_dump -U aru_admin -d axiom_memories | gzip > $BACKUP_DIR/axiom_memories-$DATE.sql.gz

# Dump cryptobot_db
docker exec axiom_db pg_dump -U aru_admin -d cryptobot_db | gzip > $BACKUP_DIR/cryptobot_db-$DATE.sql.gz

# Retention 30 hari
find $BACKUP_DIR -name "*.sql.gz" -mtime +30 -delete

# Upload mingguan ke Backblaze B2 (Senin)
if [ "$(date +%u)" = "1" ]; then
  /root/axiom_core/scripts/upload_to_b2.sh
fi
```

### 8.2 WAL Archiving (Optional, untuk PITR)

Untuk Point-in-Time Recovery, aktifkan WAL archiving di Postgres:

```ini
# postgresql.conf inside axiom_db container
wal_level = replica
archive_mode = on
archive_command = 'cp %p /backup/wal/%f'
```

Mount `./data/wal_archive:/backup/wal` di docker-compose, lalu rsync periodically ke external storage.

### 8.3 Restore Procedure

```bash
# 1. Stop semua service yang akses DB
docker-compose stop axiom-brain axiom-pattern axiom-consensus cryptobot_main cryptobot_param_sync

# 2. Drop existing DB (HATI-HATI — pakai hanya saat DR)
docker exec axiom_db psql -U aru_admin -c "DROP DATABASE IF EXISTS cryptobot_db; CREATE DATABASE cryptobot_db;"

# 3. Restore dari backup terbaru
gunzip -c /root/axiom_backups/postgres/cryptobot_db-{date}.sql.gz | docker exec -i axiom_db psql -U aru_admin -d cryptobot_db

# 4. Verify row counts
docker exec axiom_db psql -U aru_admin -d cryptobot_db -c "SELECT count(*) FROM trades;"

# 5. Restart services
docker-compose start cryptobot_main axiom-brain ...
```

---

## 9. STORAGE GROWTH PROJECTION

| Tabel | Row/hari (estimasi) | Size/row | Growth/bulan (uncompressed) | Growth/bulan (after compression) |
|---|---|---|---|---|
| `trades` | 30-100 | ~300 B | 1-3 MB | 0.3-0.8 MB |
| `bot_events` | 500-2000 | ~500 B | 7-30 MB | 1-3 MB |
| `ares_market_scans` | 2880 (30s × 1 pair) × 8 pair = 23k | ~2 KB | ~1.5 GB | ~150 MB |
| `news_items` | 50-200 | ~3 KB | ~10 MB | ~2 MB |
| `claude_usage` | 100-500 | ~200 B | ~3 MB | ~0.5 MB |
| `cross_exchange_signals` | 17k (60s × 12 pairs × 4 exch) | ~1.5 KB | ~750 MB | ~75 MB |
| `pattern_discoveries` | 5-20 | ~5 KB | ~3 MB | (no compression) |
| Total | | | **~2.3 GB/bulan** | **~230 MB/bulan after compression** |

Setelah 1 tahun di VPS 30 (200 GB NVMe): ~3 GB total — sangat fit. Bahkan setelah 5 tahun: ~15 GB. Disk **bukan** bottleneck.

---

## CURRENT STATE

**Last sync:** 2026-04-27

- ✅ Schema design final untuk axiom_memories (3 tabel existing + 8 tabel baru)
- ✅ Schema design final untuk cryptobot_db (12 tabel diport dari Supabase, 4 jadi hypertable)
- ✅ Access control matrix terdefinisi (5 user role)
- ✅ Index strategy untuk hot queries terdokumentasi
- ✅ Migration plan Supabase → local Postgres tertulis
- ✅ Backup strategy: daily pg_dump + weekly B2 upload
- ⏳ File `init.sql` di repo: **belum** mencerminkan schema baru — wajib regenerate (akan dibuat di Phase 1)
- ⏳ Migration script Supabase: **belum** ada — akan dibuat saat eksekusi M2 milestone
- ⏳ PgBouncer config + container: **belum** ada di docker-compose — wajib tambah (Phase 1)
- ⏳ asyncpg port di crypto-bot's `database/client.py`: **belum** dilakukan, butuh PR

---

## NEXT ACTION

**Untuk Claude Code:**

1. Generate file `init.sql` baru yang **menggabungkan**:
   - Existing axiom tables (knowledge_base, kai_ledger, ares_market_scans → upgrade ke hypertable)
   - 8 tabel observability baru (axiom_evaluations, consensus_log, parameter_versions, pattern_discoveries, intervention_log, code_change_audit, axiom_proposals, cross_exchange_signals)
   - User/role + GRANT statements

2. Generate file `init_cryptobot_db.sql` terpisah untuk `cryptobot_db` (tabel ex-Supabase + hypertable conversions + LISTEN/NOTIFY triggers)

3. Tambahkan service `axiom_pgbouncer` di docker-compose (refer ARCHITECTURE.md section 5)

4. Setelah file `init.sql` siap, **JANGAN langsung apply ke production** — hanya ke local Postgres untuk M1 validation. Production apply jadi bagian M2.

5. Test di local: spin up Postgres+TimescaleDB container → apply init → verify hypertable creation:
   ```bash
   docker exec axiom_db psql -U aru_admin -d axiom_memories -c \
     "SELECT hypertable_name FROM timescaledb_information.hypertables;"
   ```
   Harus return: `ares_market_scans, axiom_evaluations, cross_exchange_signals` (minimum)

→ Lanjut ke **[AI_CAPABILITIES.md](./AI_CAPABILITIES.md)** untuk pelajari layer AI yang akan dibangun di atas schema ini.
