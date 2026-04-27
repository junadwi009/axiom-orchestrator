-- =============================================================================
-- init_cryptobot_db.sql
-- Database: cryptobot_db
-- Schema migrasi dari Supabase ke local Postgres + TimescaleDB
-- Eksekusi otomatis oleh container axiom_db saat first boot (mount /docker-entrypoint-initdb.d/)
-- =============================================================================
-- Catatan:
-- 1. File ini di-run SETELAH init.sql (axiom_memories) karena urutan alfabet.
--    Pastikan filename prefix mempertahankan urutan: 01_init.sql, 02_init_cryptobot_db.sql
-- 2. Database cryptobot_db dibuat manual di init.sql atau via setup script.
-- 3. Hypertables TimescaleDB dipakai untuk: trades, bot_events, news_items, claude_usage.
-- =============================================================================

\connect cryptobot_db

-- =============================================================================
-- EXTENSIONS
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================================================
-- TABLE: bot_state
-- Single-row state machine untuk bot (PIN status, paper/live mode, etc.)
-- =============================================================================
CREATE TABLE IF NOT EXISTS bot_state (
    id              SERIAL PRIMARY KEY,
    is_unlocked     BOOLEAN     NOT NULL DEFAULT FALSE,
    paper_trade     BOOLEAN     NOT NULL DEFAULT TRUE,
    initial_capital NUMERIC(18,8) NOT NULL DEFAULT 213,
    current_capital NUMERIC(18,8) NOT NULL DEFAULT 213,
    daily_target_pct NUMERIC(5,2) NOT NULL DEFAULT 3.0,    -- Konflik 10: 3% bukan 9.1%
    max_drawdown_pct NUMERIC(5,2) NOT NULL DEFAULT 15.0,   -- guillotine threshold
    circuit_breaker_active BOOLEAN NOT NULL DEFAULT FALSE,
    last_heartbeat  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Single row enforced via partial unique index
CREATE UNIQUE INDEX IF NOT EXISTS bot_state_singleton ON bot_state ((id IS NOT NULL));

INSERT INTO bot_state (is_unlocked, paper_trade, initial_capital, current_capital)
VALUES (FALSE, TRUE, 213, 213)
ON CONFLICT DO NOTHING;

-- =============================================================================
-- TABLE: strategy_params (versioned parameter store - target Channel B writes dari axiom)
-- =============================================================================
CREATE TABLE IF NOT EXISTS strategy_params (
    id              BIGSERIAL PRIMARY KEY,
    pair            TEXT        NOT NULL,
    regime          TEXT        NOT NULL DEFAULT 'default',  -- 'calm'|'trending'|'chaos'|'default'
    rsi_oversold    NUMERIC(5,2) NOT NULL DEFAULT 30.0,
    rsi_overbought  NUMERIC(5,2) NOT NULL DEFAULT 70.0,
    sl_pct          NUMERIC(5,2) NOT NULL DEFAULT 2.0,
    tp_pct          NUMERIC(5,2) NOT NULL DEFAULT 4.0,
    max_position_pct NUMERIC(5,2) NOT NULL DEFAULT 25.0,
    extra_json      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    version         INT         NOT NULL DEFAULT 1,
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    proposed_by     TEXT        NOT NULL DEFAULT 'human',    -- 'human'|'axiom_ares'|'axiom_kai'|...
    proposal_id     UUID,                                    -- FK ke axiom_memories.axiom_proposals (cross-DB, no enforcement)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    activated_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_strategy_params_active ON strategy_params (pair, regime, is_active)
WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_strategy_params_proposal ON strategy_params (proposal_id);

-- Trigger: hanya boleh 1 baris is_active=TRUE per (pair, regime)
CREATE OR REPLACE FUNCTION enforce_single_active_param() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.is_active = TRUE THEN
        UPDATE strategy_params
        SET is_active = FALSE
        WHERE pair = NEW.pair
          AND regime = NEW.regime
          AND id != NEW.id
          AND is_active = TRUE;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_single_active_param ON strategy_params;
CREATE TRIGGER trg_single_active_param
AFTER INSERT OR UPDATE OF is_active ON strategy_params
FOR EACH ROW EXECUTE FUNCTION enforce_single_active_param();

-- Seed default params (untuk pair utama; tambah lain via Channel B)
INSERT INTO strategy_params (pair, regime, rsi_oversold, rsi_overbought, sl_pct, tp_pct, max_position_pct, proposed_by)
VALUES
    ('BTCUSDT', 'default', 30.0, 70.0, 2.0, 4.0, 25.0, 'human'),
    ('ETHUSDT', 'default', 30.0, 70.0, 2.0, 4.0, 25.0, 'human'),
    ('SOLUSDT', 'default', 28.0, 72.0, 2.5, 5.0, 20.0, 'human')
ON CONFLICT DO NOTHING;

-- =============================================================================
-- TABLE: trades (HYPERTABLE) — semua trade execution
-- =============================================================================
CREATE TABLE IF NOT EXISTS trades (
    id              BIGSERIAL,
    trade_id        UUID        NOT NULL DEFAULT uuid_generate_v4(),
    pair            TEXT        NOT NULL,
    side            TEXT        NOT NULL CHECK (side IN ('BUY','SELL')),
    entry_price     NUMERIC(18,8) NOT NULL,
    exit_price      NUMERIC(18,8),
    qty             NUMERIC(18,8) NOT NULL,
    sl_price        NUMERIC(18,8),
    tp_price        NUMERIC(18,8),
    pnl_usdt        NUMERIC(18,8),
    pnl_pct         NUMERIC(8,4),
    fees_usdt       NUMERIC(18,8) DEFAULT 0,
    slippage_pct    NUMERIC(8,4),
    status          TEXT        NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CLOSED','LIQUIDATED','CANCELLED')),
    is_paper        BOOLEAN     NOT NULL DEFAULT TRUE,
    rule_based_score NUMERIC(5,2),
    haiku_score     NUMERIC(5,2),
    sonnet_decision JSONB,
    strategy_params_id BIGINT REFERENCES strategy_params(id),
    bybit_order_id  TEXT,
    opened_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at       TIMESTAMPTZ,
    PRIMARY KEY (id, opened_at)
);

-- Convert ke hypertable (partition by opened_at, chunk 7 hari)
SELECT create_hypertable('trades', 'opened_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_trades_pair_time ON trades (pair, opened_at DESC);
CREATE INDEX IF NOT EXISTS idx_trades_status ON trades (status, opened_at DESC) WHERE status = 'OPEN';
CREATE INDEX IF NOT EXISTS idx_trades_trade_id ON trades (trade_id);

-- Compression policy: kompres chunk lebih tua dari 30 hari
ALTER TABLE trades SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'pair',
    timescaledb.compress_orderby = 'opened_at DESC'
);

SELECT add_compression_policy('trades', INTERVAL '30 days', if_not_exists => TRUE);

-- Retention policy: hapus chunk lebih tua dari 2 tahun
SELECT add_retention_policy('trades', INTERVAL '730 days', if_not_exists => TRUE);

-- =============================================================================
-- TABLE: bot_events (HYPERTABLE) — log semua event sistem
-- =============================================================================
CREATE TABLE IF NOT EXISTS bot_events (
    id              BIGSERIAL,
    event_type      TEXT        NOT NULL,
    severity        TEXT        NOT NULL DEFAULT 'INFO' CHECK (severity IN ('DEBUG','INFO','WARN','ERROR','CRITICAL')),
    component       TEXT        NOT NULL,
    payload         JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, created_at)
);

SELECT create_hypertable('bot_events', 'created_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_bot_events_type_time ON bot_events (event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bot_events_severity ON bot_events (severity, created_at DESC) WHERE severity IN ('ERROR','CRITICAL');

ALTER TABLE bot_events SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'event_type',
    timescaledb.compress_orderby = 'created_at DESC'
);

SELECT add_compression_policy('bot_events', INTERVAL '14 days', if_not_exists => TRUE);
SELECT add_retention_policy('bot_events', INTERVAL '180 days', if_not_exists => TRUE);

-- =============================================================================
-- TABLE: news_items (HYPERTABLE) — news scraping & sentiment
-- =============================================================================
CREATE TABLE IF NOT EXISTS news_items (
    id              BIGSERIAL,
    source          TEXT        NOT NULL,
    headline        TEXT        NOT NULL,
    url             TEXT        UNIQUE,
    pairs_affected  TEXT[]      NOT NULL DEFAULT '{}',
    sentiment_score NUMERIC(4,3),         -- -1.0 to +1.0
    urgency_score   NUMERIC(4,3),         -- 0.0 to 1.0 (haiku output)
    raw_content     TEXT,
    haiku_classification JSONB,
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, fetched_at)
);

SELECT create_hypertable('news_items', 'fetched_at',
    chunk_time_interval => INTERVAL '14 days',
    if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_news_pairs ON news_items USING GIN (pairs_affected);
CREATE INDEX IF NOT EXISTS idx_news_urgency ON news_items (urgency_score DESC, fetched_at DESC)
WHERE urgency_score > 0.7;

ALTER TABLE news_items SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'fetched_at DESC'
);

SELECT add_compression_policy('news_items', INTERVAL '30 days', if_not_exists => TRUE);
SELECT add_retention_policy('news_items', INTERVAL '365 days', if_not_exists => TRUE);

-- =============================================================================
-- TABLE: claude_usage (HYPERTABLE) — cost tracking Anthropic API
-- =============================================================================
CREATE TABLE IF NOT EXISTS claude_usage (
    id              BIGSERIAL,
    model           TEXT        NOT NULL,           -- 'claude-haiku-4-5'|'claude-sonnet-4-6'|'claude-opus-4-7'
    input_tokens    INT         NOT NULL,
    output_tokens   INT         NOT NULL,
    cache_read_tokens INT       NOT NULL DEFAULT 0,
    cache_write_tokens INT      NOT NULL DEFAULT 0,
    cost_usd        NUMERIC(10,6) NOT NULL,
    purpose         TEXT,                            -- 'haiku_filter'|'sonnet_decide'|'opus_weekly'|'opus_consensus'
    trade_id        UUID,                            -- FK ke trades.trade_id (nullable)
    request_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (id, request_at)
);

SELECT create_hypertable('claude_usage', 'request_at',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_claude_usage_model_time ON claude_usage (model, request_at DESC);

ALTER TABLE claude_usage SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'model',
    timescaledb.compress_orderby = 'request_at DESC'
);

SELECT add_compression_policy('claude_usage', INTERVAL '14 days', if_not_exists => TRUE);
SELECT add_retention_policy('claude_usage', INTERVAL '365 days', if_not_exists => TRUE);

-- =============================================================================
-- TABLE: pin_attempts (security audit trail untuk PIN unlock)
-- =============================================================================
CREATE TABLE IF NOT EXISTS pin_attempts (
    id              BIGSERIAL PRIMARY KEY,
    success         BOOLEAN     NOT NULL,
    ip_address      INET,
    user_agent      TEXT,
    attempted_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_pin_attempts_time ON pin_attempts (attempted_at DESC);

-- =============================================================================
-- TABLE: circuit_breaker_log
-- =============================================================================
CREATE TABLE IF NOT EXISTS circuit_breaker_log (
    id              BIGSERIAL PRIMARY KEY,
    triggered_by    TEXT        NOT NULL,           -- 'drawdown'|'consecutive_loss'|'liquidity'|'axiom_thanatos'
    reason          TEXT        NOT NULL,
    snapshot        JSONB       NOT NULL DEFAULT '{}'::jsonb,
    auto_resolved   BOOLEAN     NOT NULL DEFAULT FALSE,
    triggered_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ
);

-- =============================================================================
-- TABLE: portfolio_snapshots (daily snapshot)
-- =============================================================================
CREATE TABLE IF NOT EXISTS portfolio_snapshots (
    id              BIGSERIAL PRIMARY KEY,
    snapshot_date   DATE        NOT NULL UNIQUE,
    total_equity    NUMERIC(18,8) NOT NULL,
    realized_pnl    NUMERIC(18,8) NOT NULL DEFAULT 0,
    unrealized_pnl  NUMERIC(18,8) NOT NULL DEFAULT 0,
    open_positions  INT         NOT NULL DEFAULT 0,
    daily_return_pct NUMERIC(8,4),
    max_drawdown_pct NUMERIC(8,4),
    sharpe_ratio    NUMERIC(8,4),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- TABLE: opus_weekly_evaluations (mirror untuk consensus)
-- Dipakai axiom untuk consensus comparison via consensus_log di axiom_memories
-- =============================================================================
CREATE TABLE IF NOT EXISTS opus_weekly_evaluations (
    id              BIGSERIAL PRIMARY KEY,
    week_starting   DATE        NOT NULL UNIQUE,
    summary         TEXT        NOT NULL,
    recommendations JSONB       NOT NULL,
    confidence      NUMERIC(4,3),
    raw_response    TEXT,
    cost_usd        NUMERIC(10,6),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- TABLE: pair_watchlist (universe of monitored pairs)
-- =============================================================================
CREATE TABLE IF NOT EXISTS pair_watchlist (
    id              SERIAL PRIMARY KEY,
    pair            TEXT        NOT NULL UNIQUE,
    enabled         BOOLEAN     NOT NULL DEFAULT TRUE,
    min_volume_24h  NUMERIC(18,2) NOT NULL DEFAULT 1000000,
    added_by        TEXT        NOT NULL DEFAULT 'human',
    added_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO pair_watchlist (pair, enabled) VALUES
    ('BTCUSDT', TRUE), ('ETHUSDT', TRUE), ('SOLUSDT', TRUE),
    ('BNBUSDT', TRUE), ('XRPUSDT', TRUE)
ON CONFLICT DO NOTHING;

-- =============================================================================
-- TABLE: signal_history (sinyal yang dihasilkan signal_generator, sebelum/sesudah filter)
-- =============================================================================
CREATE TABLE IF NOT EXISTS signal_history (
    id              BIGSERIAL PRIMARY KEY,
    pair            TEXT        NOT NULL,
    signal_type     TEXT        NOT NULL,           -- 'BUY'|'SELL'
    rule_based_passed BOOLEAN   NOT NULL,
    haiku_passed    BOOLEAN,
    sonnet_passed   BOOLEAN,
    final_executed  BOOLEAN     NOT NULL DEFAULT FALSE,
    rejection_reason TEXT,
    indicators      JSONB       NOT NULL DEFAULT '{}'::jsonb,
    generated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_signal_history_pair_time ON signal_history (pair, generated_at DESC);

-- =============================================================================
-- TABLE: api_keys_meta (TIDAK menyimpan kunci! hanya metadata: rotated_at, label, scope)
-- =============================================================================
CREATE TABLE IF NOT EXISTS api_keys_meta (
    id              SERIAL PRIMARY KEY,
    label           TEXT        NOT NULL UNIQUE,    -- 'bybit_main'|'bybit_paper'|'anthropic_main'
    scope           TEXT,
    last_rotated_at TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ,
    notes           TEXT
);

-- =============================================================================
-- LISTEN/NOTIFY TRIGGERS untuk Channel A bridge (axiom_bridge subscribes)
-- =============================================================================

-- Trigger 1: notify saat trade baru di-insert
CREATE OR REPLACE FUNCTION notify_trade_inserted() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('trade_inserted', json_build_object(
        'trade_id', NEW.trade_id,
        'pair', NEW.pair,
        'side', NEW.side,
        'status', NEW.status,
        'is_paper', NEW.is_paper,
        'opened_at', NEW.opened_at
    )::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notify_trade ON trades;
CREATE TRIGGER trg_notify_trade
AFTER INSERT ON trades
FOR EACH ROW EXECUTE FUNCTION notify_trade_inserted();

-- Trigger 2: notify saat trade di-CLOSE (status berubah jadi CLOSED/LIQUIDATED)
CREATE OR REPLACE FUNCTION notify_trade_closed() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status IN ('CLOSED', 'LIQUIDATED') AND OLD.status = 'OPEN' THEN
        PERFORM pg_notify('trade_closed', json_build_object(
            'trade_id', NEW.trade_id,
            'pair', NEW.pair,
            'pnl_usdt', NEW.pnl_usdt,
            'pnl_pct', NEW.pnl_pct,
            'closed_at', NEW.closed_at
        )::text);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notify_trade_closed ON trades;
CREATE TRIGGER trg_notify_trade_closed
AFTER UPDATE OF status ON trades
FOR EACH ROW EXECUTE FUNCTION notify_trade_closed();

-- Trigger 3: notify saat event severity tinggi
CREATE OR REPLACE FUNCTION notify_critical_event() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.severity IN ('ERROR', 'CRITICAL') THEN
        PERFORM pg_notify('event_inserted', json_build_object(
            'event_type', NEW.event_type,
            'severity', NEW.severity,
            'component', NEW.component,
            'created_at', NEW.created_at
        )::text);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notify_event ON bot_events;
CREATE TRIGGER trg_notify_event
AFTER INSERT ON bot_events
FOR EACH ROW EXECUTE FUNCTION notify_critical_event();

-- Trigger 4: notify saat circuit breaker trigger
CREATE OR REPLACE FUNCTION notify_circuit_breaker() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify('circuit_breaker', json_build_object(
        'triggered_by', NEW.triggered_by,
        'reason', NEW.reason,
        'triggered_at', NEW.triggered_at
    )::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notify_breaker ON circuit_breaker_log;
CREATE TRIGGER trg_notify_breaker
AFTER INSERT ON circuit_breaker_log
FOR EACH ROW EXECUTE FUNCTION notify_circuit_breaker();

-- =============================================================================
-- ROLE GRANTS
-- =============================================================================
-- Asumsikan role sudah dibuat di init.sql:
--   cryptobot_user, readonly_observer, parameter_sync_user, n8n_user

-- cryptobot_user: full ownership atas cryptobot_db
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO cryptobot_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO cryptobot_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO cryptobot_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO cryptobot_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO cryptobot_user;

-- readonly_observer: SELECT only (axiom_brain pakai role ini untuk observasi)
GRANT USAGE ON SCHEMA public TO readonly_observer;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_observer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly_observer;

-- parameter_sync_user: HANYA INSERT/UPDATE strategy_params (Channel B)
GRANT USAGE ON SCHEMA public TO parameter_sync_user;
GRANT SELECT, INSERT, UPDATE ON strategy_params TO parameter_sync_user;
GRANT USAGE, SELECT ON SEQUENCE strategy_params_id_seq TO parameter_sync_user;
GRANT SELECT ON bot_state, pair_watchlist TO parameter_sync_user;
-- DENY semua tabel lain implicitly (tidak ada GRANT lain)

-- n8n_user: SELECT untuk dashboard
GRANT USAGE ON SCHEMA public TO n8n_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO n8n_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO n8n_user;

-- =============================================================================
-- INITIAL DATA SEED
-- =============================================================================
INSERT INTO bot_events (event_type, severity, component, payload)
VALUES (
    'DATABASE_INITIALIZED',
    'INFO',
    'init_cryptobot_db.sql',
    json_build_object(
        'version', '1.0',
        'timescale_enabled', true,
        'hypertables', json_build_array('trades','bot_events','news_items','claude_usage'),
        'migrated_from', 'supabase'
    )::jsonb
);

-- =============================================================================
-- END of init_cryptobot_db.sql
-- =============================================================================
