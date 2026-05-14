-- =============================================================================
-- init.sql — schema untuk database axiom_memories
-- =============================================================================
-- Auto-loaded saat container axiom_db (timescale/timescaledb:latest-pg16)
-- pertama kali start. Mounted di docker-compose sebagai
-- /docker-entrypoint-initdb.d/01_init_axiom.sql
-- =============================================================================

-- Buat database axiom_memories adalah default (dari POSTGRES_DB env).
-- Disini kita load extensions dan create tables di axiom_memories.

-- =============================================================================
-- EXTENSIONS
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- =============================================================================
-- USERS & ROLES (akan dibuat di kedua database)
-- =============================================================================
-- Note: ini akan di-applied via ALTER DEFAULT PRIVILEGES + GRANT setelah
-- table dibuat. User created di session awal.

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'axiom_user') THEN
        CREATE USER axiom_user WITH PASSWORD 'PLACEHOLDER_AXIOM_PASSWORD';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'cryptobot_user') THEN
        CREATE USER cryptobot_user WITH PASSWORD 'PLACEHOLDER_CRYPTOBOT_PASSWORD';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'readonly_observer') THEN
        CREATE USER readonly_observer WITH PASSWORD 'PLACEHOLDER_OBSERVER_PASSWORD';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'parameter_sync_user') THEN
        CREATE USER parameter_sync_user WITH PASSWORD 'PLACEHOLDER_PARAMSYNC_PASSWORD';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'n8n_user') THEN
        CREATE USER n8n_user WITH PASSWORD 'PLACEHOLDER_N8N_PASSWORD';
    END IF;
    -- Phase 1.5 Stack-B Item 3: dedicated pgbouncer auth_user (no superuser for pooler)
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'pgbouncer_auth') THEN
        CREATE USER pgbouncer_auth WITH PASSWORD 'PLACEHOLDER_PGBOUNCER_AUTH_PASSWORD';
    END IF;
END
$$;

-- ⚠️  PENTING: Ganti PLACEHOLDER_* dengan password actual via:
-- ALTER USER axiom_user WITH PASSWORD '...';
-- Run script set_passwords.sh setelah init selesai (auto-executed by docker-entrypoint).

-- =============================================================================
-- PGBOUNCER AUTH SUPPORT (Phase 1.5 Stack-B Item 3)
-- =============================================================================
-- Dedicated schema + SECURITY DEFINER function so pgbouncer can run auth_query
-- with a non-superuser. Pattern from Crunchy Data:
-- https://www.crunchydata.com/blog/pgbouncer-scram-authentication-postgresql
CREATE SCHEMA IF NOT EXISTS pgbouncer;
CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_username TEXT)
    RETURNS TABLE(username TEXT, password TEXT)
    LANGUAGE sql
    SECURITY DEFINER
AS $func$
    SELECT usename::TEXT, passwd::TEXT
    FROM pg_catalog.pg_shadow
    WHERE usename = p_username;
$func$;
REVOKE ALL ON FUNCTION pgbouncer.get_auth(TEXT) FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer_auth;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(TEXT) TO pgbouncer_auth;

-- =============================================================================
-- AXIOM_MEMORIES — TABEL EXISTING (dari init.sql v2 axiom)
-- =============================================================================

-- knowledge_base: penyimpanan persona/protocol agen Hermes Council
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
CREATE INDEX IF NOT EXISTS idx_kb_entity  ON knowledge_base(entity_source);
CREATE INDEX IF NOT EXISTS idx_kb_pattern ON knowledge_base(pattern_name);
-- FTS index for protocol_content + logic_summary retrieval (knowledge_manager queries).
-- Use 'simple' config (no language-specific stemming) since content is mixed Bahasa Indonesia + English.
ALTER TABLE knowledge_base ADD COLUMN IF NOT EXISTS tsv tsvector
    GENERATED ALWAYS AS (
        to_tsvector('simple',
            coalesce(protocol_content, '') || ' ' || coalesce(logic_summary, ''))
    ) STORED;
CREATE INDEX IF NOT EXISTS idx_kb_fts ON knowledge_base USING GIN(tsv);

-- kai_ledger: audit harian dari Kai (CFO agent)
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

-- ares_market_scans: HYPERTABLE — snapshot pasar dari Ares analyzer
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

SELECT create_hypertable('ares_market_scans', 'scan_timestamp',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_ares_sym_time
    ON ares_market_scans(symbol, scan_timestamp DESC);

-- Compression policy: kompres chunk umur > 7 hari
ALTER TABLE ares_market_scans SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'symbol'
);
SELECT add_compression_policy('ares_market_scans', INTERVAL '7 days', if_not_exists => TRUE);

-- Retention: drop chunk umur > 180 hari
SELECT add_retention_policy('ares_market_scans', INTERVAL '180 days', if_not_exists => TRUE);

-- Continuous aggregate: ringkasan harian per symbol
CREATE MATERIALIZED VIEW IF NOT EXISTS ares_market_scans_daily
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
    end_offset   => INTERVAL '1 hour',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists => TRUE);

-- =============================================================================
-- TABEL BARU UNTUK OBSERVABILITY & SELF-IMPROVEMENT
-- =============================================================================

-- axiom_evaluations: HYPERTABLE — hasil evaluasi axiom terhadap keputusan crypto-bot
CREATE TABLE IF NOT EXISTS axiom_evaluations (
    id                  BIGSERIAL,
    evaluated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    evaluation_type     VARCHAR(30) NOT NULL,    -- 'trade_review' | 'strategy_review' | 'weekly_consensus'
    target_entity       VARCHAR(50),             -- mis. 'trade:uuid' | 'pair:BTC/USDT'
    evaluator           VARCHAR(30) NOT NULL,    -- 'hermes_council' | 'pattern_layer1' | 'rl_layer3'
    verdict             VARCHAR(20),             -- 'optimal' | 'suboptimal' | 'concerning' | 'critical'
    confidence_score    DECIMAL(4, 3),
    findings            JSONB NOT NULL,
    recommended_action  TEXT,
    proposal_id         UUID,                    -- nullable FK ke axiom_proposals
    PRIMARY KEY (evaluated_at, id)
);

SELECT create_hypertable('axiom_evaluations', 'evaluated_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_axeval_target
    ON axiom_evaluations(target_entity, evaluated_at DESC);
CREATE INDEX IF NOT EXISTS idx_axeval_type
    ON axiom_evaluations(evaluation_type, evaluated_at DESC);

-- consensus_log: Opus vs Hermes Council weekly comparison
CREATE TABLE IF NOT EXISTS consensus_log (
    id                       SERIAL PRIMARY KEY,
    consensus_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    period_start             DATE NOT NULL,
    period_end               DATE NOT NULL,
    opus_summary             TEXT,
    opus_recommendations     JSONB,
    hermes_summary           TEXT,
    hermes_recommendations   JSONB,
    agreement_level          VARCHAR(20),    -- 'unanimous' | 'majority' | 'split' | 'opposing'
    final_decision           VARCHAR(30),    -- 'apply_opus' | 'apply_hermes' | 'apply_consensus' | 'tiebreaker_required' | 'hold'
    tiebreaker_used          VARCHAR(30),
    tiebreaker_output        TEXT,
    proposal_ids_generated   UUID[],
    cost_breakdown           JSONB,
    raw_opus_response        TEXT,
    raw_hermes_chat_history  JSONB
);

CREATE INDEX IF NOT EXISTS idx_consensus_period ON consensus_log(period_start DESC);

-- parameter_versions: audit trail setiap perubahan parameter
CREATE TABLE IF NOT EXISTS parameter_versions (
    id              SERIAL PRIMARY KEY,
    target_table    VARCHAR(50) NOT NULL,
    target_pk       VARCHAR(100) NOT NULL,
    version_number  INT NOT NULL,
    snapshot_before JSONB NOT NULL,
    snapshot_after  JSONB NOT NULL,
    diff            JSONB NOT NULL,
    changed_by      VARCHAR(50) NOT NULL,
    proposal_id     UUID,
    reason          TEXT,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_param_version UNIQUE (target_table, target_pk, version_number)
);

CREATE INDEX IF NOT EXISTS idx_param_target
    ON parameter_versions(target_table, target_pk, version_number DESC);
CREATE INDEX IF NOT EXISTS idx_param_time
    ON parameter_versions(changed_at DESC);

-- pattern_discoveries: pola hasil temuan axiom-pattern
CREATE TABLE IF NOT EXISTS pattern_discoveries (
    id                       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    discovered_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    discovered_by            VARCHAR(30) NOT NULL,
    pattern_type             VARCHAR(50) NOT NULL,
    pair                     VARCHAR(20),
    evidence_window_start    TIMESTAMPTZ NOT NULL,
    evidence_window_end      TIMESTAMPTZ NOT NULL,
    occurrences              INT NOT NULL,
    precision_score          DECIMAL(4, 3),
    recall_score             DECIMAL(4, 3),
    expected_outcome         TEXT,
    expected_horizon_minutes INT,
    pattern_signature        JSONB NOT NULL,
    sample_event_ids         UUID[],
    status                   VARCHAR(20) DEFAULT 'candidate',
    promoted_to_proposal_id  UUID,
    notes                    TEXT
);

CREATE INDEX IF NOT EXISTS idx_pattern_type   ON pattern_discoveries(pattern_type);
CREATE INDEX IF NOT EXISTS idx_pattern_pair   ON pattern_discoveries(pair);
CREATE INDEX IF NOT EXISTS idx_pattern_status ON pattern_discoveries(status);
CREATE INDEX IF NOT EXISTS idx_pattern_disc   ON pattern_discoveries(discovered_at DESC);

-- intervention_log: log setiap intervensi axiom ke crypto-bot
CREATE TABLE IF NOT EXISTS intervention_log (
    id                  SERIAL PRIMARY KEY,
    intervened_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    channel             VARCHAR(1) NOT NULL CHECK (channel IN ('A','B','C')),
    action_type         VARCHAR(30) NOT NULL,
    target              VARCHAR(100),
    payload             JSONB NOT NULL,
    triggered_by        VARCHAR(50) NOT NULL,
    initiated_by_id     UUID,
    outcome             VARCHAR(20),
    outcome_at          TIMESTAMPTZ,
    outcome_notes       TEXT
);

CREATE INDEX IF NOT EXISTS idx_interv_channel ON intervention_log(channel, intervened_at DESC);
CREATE INDEX IF NOT EXISTS idx_interv_target  ON intervention_log(target);

-- code_change_audit: audit trail untuk Channel C (code rewrite)
CREATE TABLE IF NOT EXISTS code_change_audit (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    proposed_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    change_type         VARCHAR(30) NOT NULL,
    target_file         VARCHAR(255) NOT NULL,
    diff_unified        TEXT NOT NULL,
    reason              TEXT NOT NULL,
    proposed_by         VARCHAR(50) NOT NULL,
    backtest_summary    JSONB,
    validation_logs     TEXT,
    asura_review        TEXT,
    status              VARCHAR(20) NOT NULL DEFAULT 'proposed',
    approved_by         VARCHAR(50),
    approved_at         TIMESTAMPTZ,
    branch_name         VARCHAR(100),
    git_commit_sha      VARCHAR(40),
    applied_at          TIMESTAMPTZ,
    rolled_back_at      TIMESTAMPTZ,
    rollback_reason     TEXT,
    rollback_pnl_delta  DECIMAL(15, 4)
);

CREATE INDEX IF NOT EXISTS idx_codechg_status ON code_change_audit(status);
CREATE INDEX IF NOT EXISTS idx_codechg_file   ON code_change_audit(target_file);
CREATE INDEX IF NOT EXISTS idx_codechg_time   ON code_change_audit(proposed_at DESC);

-- axiom_proposals: pipeline untuk Channel B (parameter rewrite)
CREATE TABLE IF NOT EXISTS axiom_proposals (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    proposal_type   VARCHAR(20) NOT NULL,
    target_table    VARCHAR(50) NOT NULL,
    target_pk       VARCHAR(100) NOT NULL,
    diff            JSONB NOT NULL,
    reason          TEXT NOT NULL,
    backtest_result JSONB,
    status          VARCHAR(20) NOT NULL DEFAULT 'proposed',
    created_by      VARCHAR(50) NOT NULL,
    approved_by     VARCHAR(50),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    validated_at    TIMESTAMPTZ,
    approved_at     TIMESTAMPTZ,
    applied_at      TIMESTAMPTZ,
    rolled_back_at  TIMESTAMPTZ,
    rollback_reason TEXT
);

CREATE INDEX IF NOT EXISTS idx_proposal_status ON axiom_proposals(status, created_at);
CREATE INDEX IF NOT EXISTS idx_proposal_target ON axiom_proposals(target_table, target_pk);

-- cross_exchange_signals: HYPERTABLE — multi-exchange scan via ccxt
CREATE TABLE IF NOT EXISTS cross_exchange_signals (
    id              BIGSERIAL,
    scanned_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    pair            VARCHAR(20) NOT NULL,
    exchange_prices JSONB NOT NULL,
    max_spread_bps  INT,
    funding_rates   JSONB,
    volume_24h      JSONB,
    arbitrage_opp   BOOLEAN DEFAULT FALSE,
    PRIMARY KEY (scanned_at, pair, id)
);

SELECT create_hypertable('cross_exchange_signals', 'scanned_at',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_crossexch_pair
    ON cross_exchange_signals(pair, scanned_at DESC);
CREATE INDEX IF NOT EXISTS idx_crossexch_arb
    ON cross_exchange_signals(arbitrage_opp) WHERE arbitrage_opp = TRUE;

ALTER TABLE cross_exchange_signals SET (
    timescaledb.compress,
    timescaledb.compress_segmentby='pair'
);
SELECT add_compression_policy('cross_exchange_signals', INTERVAL '7 days', if_not_exists => TRUE);
SELECT add_retention_policy('cross_exchange_signals', INTERVAL '90 days', if_not_exists => TRUE);

-- =============================================================================
-- BUAT DATABASE cryptobot_db
-- =============================================================================
-- Note: CREATE DATABASE tidak bisa di-jalankan dalam transaksi yang sudah connect ke
-- database tertentu. Postgres docker-entrypoint-initdb.d auto-runs file ini di
-- database POSTGRES_DB (axiom_memories), jadi kita pakai dblink atau external script.
-- Solusi: file ini hanya untuk axiom_memories. cryptobot_db dibuat oleh
-- 02_init_cryptobot.sql via docker-entrypoint trick:

CREATE DATABASE cryptobot_db OWNER aru_admin
    ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8'
    TEMPLATE template0;

-- =============================================================================
-- GRANTS — axiom_memories database
-- =============================================================================

GRANT CONNECT ON DATABASE axiom_memories TO axiom_user, readonly_observer, n8n_user;
GRANT USAGE ON SCHEMA public TO axiom_user, readonly_observer, n8n_user;

-- axiom_user: full access ke axiom_memories
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO axiom_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO axiom_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO axiom_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO axiom_user;

-- readonly_observer: read-only ke axiom_memories
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_observer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly_observer;

-- n8n_user: full access untuk workflow data
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO n8n_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO n8n_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO n8n_user;

-- =============================================================================
-- INITIAL DATA SEED (optional)
-- =============================================================================

-- Pre-insert agen identities ke knowledge_base (jika belum ada)
INSERT INTO knowledge_base (entity_source, pattern_name, protocol_content, confidence_score, file_path)
VALUES
('Sistem', 'BIRTH_CERTIFICATE',
 'Axiom Core diaktifkan. Mode self-hosted di VPS Contabo Ubuntu 24.04.', 100.0,
 '/app/core_memory/00_SOVEREIGN_SOUL.md')
ON CONFLICT (entity_source, pattern_name) DO NOTHING;

-- =============================================================================
-- END OF init.sql for axiom_memories
-- =============================================================================
