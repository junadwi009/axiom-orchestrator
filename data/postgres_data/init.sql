-- ==============================================================================
-- PROJECT AXIOM: DATABASE SCHEMA (V2 - FIXED)
-- [FIXED]: UNIQUE constraint pada knowledge_base agar ON CONFLICT berfungsi
-- [ADDED]: Tabel trade_executions untuk riwayat order nyata dari Executioner
-- ==============================================================================

-- 1. KNOWLEDGE BASE
CREATE TABLE IF NOT EXISTS knowledge_base (
    id               SERIAL PRIMARY KEY,
    entity_source    VARCHAR(20)  NOT NULL,
    pattern_name     VARCHAR(100) NOT NULL,
    protocol_content TEXT,
    pattern_data     JSONB,
    logic_summary    TEXT,
    confidence_score DECIMAL(5, 2) DEFAULT 100.0,
    file_path        VARCHAR(255),
    last_synced      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_kb_source_pattern UNIQUE (entity_source, pattern_name)
);

-- 2. ARES MARKET PULSE
CREATE TABLE IF NOT EXISTS ares_market_scans (
    id                 SERIAL PRIMARY KEY,
    symbol             VARCHAR(20)   NOT NULL,
    current_price      DECIMAL(20, 10),
    volatility_spread  DECIMAL(20, 10),
    liquidity_gap      DECIMAL(20, 10),
    best_bid           DECIMAL(20, 10),
    best_ask           DECIMAL(20, 10),
    raw_ohlcv_snapshot JSONB,
    scan_timestamp     TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 3. KAI FISCAL LEDGER
CREATE TABLE IF NOT EXISTS kai_ledger (
    id                      SERIAL PRIMARY KEY,
    day_count               INT UNIQUE,
    actual_balance          DECIMAL(20, 2),
    expected_balance        DECIMAL(20, 2),
    deficit_surplus         DECIMAL(20, 2),
    opex_cost               DECIMAL(15, 4) DEFAULT 0,
    is_compounding_on_track BOOLEAN,
    audit_log               TEXT,
    created_at              TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 4. [NEW] TRADE EXECUTIONS — Riwayat order nyata dari Executioner (bot.py)
--    Kai pakai ini untuk audit PnL aktual, Asura untuk verifikasi integritas.
CREATE TABLE IF NOT EXISTS trade_executions (
    id           SERIAL PRIMARY KEY,
    order_id     VARCHAR(100),
    symbol       VARCHAR(20)  NOT NULL,
    action       VARCHAR(10)  NOT NULL,   -- BUY / SELL
    size_usd     DECIMAL(15, 4),
    amount_coin  DECIMAL(20, 10),
    entry_price  DECIMAL(20, 10),
    is_paper     BOOLEAN DEFAULT TRUE,
    raw_response JSONB,
    executed_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_kb_entity  ON knowledge_base(entity_source);
CREATE INDEX IF NOT EXISTS idx_kb_pattern ON knowledge_base(pattern_name);
CREATE INDEX IF NOT EXISTS idx_ares_sym   ON ares_market_scans(symbol);
CREATE INDEX IF NOT EXISTS idx_trade_sym  ON trade_executions(symbol);
CREATE INDEX IF NOT EXISTS idx_trade_time ON trade_executions(executed_at DESC);
