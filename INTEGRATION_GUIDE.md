# INTEGRATION_GUIDE.md — KONTRAK ANTAR KOMPONEN

> **Status:** AUTHORITATIVE | **Owner:** Aru (aru009)
> File ini definisikan **kontrak teknis** antara axiom dan crypto-bot.
> Setiap perubahan kontrak **wajib** update di sini sebelum implementasi.

→ Prerequisite: **[ARCHITECTURE.md](./ARCHITECTURE.md)** sudah dibaca.

---

## 1. PRINSIP KONTRAK

Tiga aturan tidak bisa dilanggar:

1. **Crypto-bot adalah produk yang berdiri sendiri**. Crypto-bot berjalan normal **walaupun axiom mati total**. Tidak boleh ada blocking dependency dari crypto-bot ke axiom.
2. **Axiom adalah observer + intervener**. Axiom **boleh** mati selama beberapa jam tanpa crypto-bot terdampak. Re-sync state otomatis saat axiom recover.
3. **Komunikasi async-only**. Tidak ada synchronous RPC dari trading hot-path. Semua axiom→crypto-bot lewat: (a) DB write yang di-poll, (b) Redis pub/sub, (c) git commit yang di-pull.

---

## 2. MEKANISME OBSERVASI (axiom membaca state crypto-bot)

### 2.1 Database Read-Only Access

Axiom punya user Postgres `readonly_observer` dengan `GRANT SELECT` ke semua tabel di `cryptobot_db`.

**Tabel utama yang axiom watch:**

| Tabel | Frekuensi poll | Tujuan |
|---|---|---|
| `cryptobot_db.trades` | Real-time via `LISTEN trade_inserted` | Track setiap trade saat baru open/close |
| `cryptobot_db.bot_events` | Real-time via `LISTEN event_inserted` | Track signals, errors, circuit breaker trips |
| `cryptobot_db.portfolio_state` | Hourly poll | Track PnL, drawdown, tier transitions |
| `cryptobot_db.opus_memory` | Weekly poll (Sunday 00:00) | Bandingkan dengan Hermes Council weekly |
| `cryptobot_db.claude_usage` | Daily poll | Audit cost & rate limit usage crypto-bot |
| `cryptobot_db.news_items` | 15-min poll (sinkron dengan news_loop) | Bahan input pattern recognition |

### 2.2 Postgres LISTEN/NOTIFY

Crypto-bot side — trigger di Postgres untuk publish event:

```sql
-- Setup di cryptobot_db (run via init.sql or migration)
CREATE OR REPLACE FUNCTION notify_trade_inserted() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('trade_inserted', json_build_object(
        'trade_id', NEW.id,
        'pair', NEW.pair,
        'side', NEW.side,
        'amount_usd', NEW.amount_usd,
        'opened_at', NEW.opened_at
    )::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trades_after_insert
AFTER INSERT ON trades
FOR EACH ROW EXECUTE FUNCTION notify_trade_inserted();
```

Axiom side — listener menggunakan psycopg2 async cursor:

```python
# agents/observability/event_listener.py (file baru)
import psycopg2
from psycopg2 import sql
import select
import json
import logging

class CryptoBotEventListener:
    """Subscribe ke Postgres NOTIFY dari cryptobot_db, forward ke handler axiom."""
    
    def __init__(self, dsn: str, handlers: dict):
        self.dsn = dsn
        self.handlers = handlers  # {"trade_inserted": callable, "event_inserted": callable}
    
    def listen_forever(self):
        conn = psycopg2.connect(self.dsn)
        conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
        cur = conn.cursor()
        for channel in self.handlers.keys():
            cur.execute(sql.SQL("LISTEN {}").format(sql.Identifier(channel)))
        
        while True:
            if select.select([conn], [], [], 60) == ([], [], []):
                continue  # timeout, loop again
            conn.poll()
            while conn.notifies:
                notify = conn.notifies.pop(0)
                handler = self.handlers.get(notify.channel)
                if handler:
                    try:
                        handler(json.loads(notify.payload))
                    except Exception as e:
                        logging.exception(f"Handler error for {notify.channel}: {e}")
```

### 2.3 Redis Pub/Sub untuk Hot Events

Crypto-bot publish ke channel `axiom:bot_events` saat sesuatu **time-sensitive** terjadi (axiom perlu reaksi < 1s):

```python
# Di crypto-bot, file utils/event_publisher.py (file baru)
async def publish_event(event_type: str, payload: dict):
    msg = json.dumps({"type": event_type, "ts": time.time(), **payload})
    await redis.publish("axiom:bot_events", msg)
```

Event types yang dipublish:
- `signal_generated` — sinyal baru lolos dari pipeline (sebelum order)
- `order_placed` — order berhasil masuk ke Bybit
- `order_failed` — order gagal eksekusi
- `position_closed` — posisi tutup (win/loss + final PnL)
- `circuit_breaker_tripped` — drawdown 15% tercapai
- `tier_changed` — capital naik/turun melewati tier threshold
- `news_shock` — sentiment shock terdeteksi
- `claude_rate_limit_warning` — usage Anthropic >80% daily limit

→ Axiom subscribe di `axiom-brain` container untuk react real-time.

### 2.4 Log File Tailing (Fallback)

Jika Postgres NOTIFY atau Redis pub/sub tidak available (mis. saat startup), axiom **boleh** tail log file crypto-bot via mounted volume:

```yaml
# docker-compose.yaml partial
services:
  cryptobot_main:
    volumes:
      - ./logs/cryptobot:/bot/logs
  axiom-brain:
    volumes:
      - ./logs:/app/logs:ro  # READ-ONLY mount
```

Axiom punya parser log untuk extract event dari log line — tapi ini **fallback only**, primary tetap Postgres/Redis.

---

## 3. MEKANISME INTERVENSI AXIOM

Axiom mengubah behavior crypto-bot lewat **3 channel**, dari yang paling ringan ke paling invasive:

### 3.1 Channel A: Redis Flag Toggle (instant, paling reversible)

Untuk perubahan **runtime state**, axiom langsung set/unset Redis flag. Crypto-bot poll flag setiap cycle.

| Flag Redis | Set by | Read by | Effect |
|---|---|---|---|
| `shared:bot_paused` | axiom or crypto-bot | crypto-bot trading_loop | jika `=1` skip cycle |
| `shared:circuit_breaker_tripped` | crypto-bot atau axiom | crypto-bot order_guard | jika `=1` reject semua order baru |
| `axiom:override_pair:{pair}` | axiom | crypto-bot signal_generator | jika `={action}`, force action selama 1 cycle |
| `axiom:auto_disabled` | Aru manual | axiom (semua module) | jika `=1`, axiom tidak boleh auto-action |
| `axiom:pattern_alert:{type}` | axiom | crypto-bot rule_based | flag pola yang baru ditemukan, crypto-bot pakai sebagai context tambahan |

Axiom set flag ini dengan TTL agar tidak stuck:
```python
await redis.setex("shared:bot_paused", ttl=3600, value="1")  # auto-clear setelah 1 jam
```

### 3.2 Channel B: Parameter Rewrite via Database (semi-permanent, dengan validasi)

Untuk perubahan **strategi**, axiom tidak update `strategy_params` langsung. Workflow:

```
[axiom-brain] → INSERT axiom_proposals (status=proposed)
                     │
                     ▼
[validator]      → backtest 30 hari + safety check
                     │ pass?
                     ▼
[axiom-brain] → UPDATE axiom_proposals (status=validated)
                     │
                     ▼ (90 hari pertama: butuh approval Aru)
[Aru via Telegram] → /approve {proposal_id}
                     │
                     ▼
[axiom-brain] → UPDATE axiom_proposals (status=approved)
                     │
                     ▼
[parameter_sync] → poll → apply ke cryptobot_db.strategy_params
                     │ (dalam transaksi: insert ke parameter_versions juga)
                     ▼
[crypto-bot]     → cycle berikutnya pakai parameter baru (tidak perlu restart)
```

**Schema `axiom_proposals` (di axiom_memories DB):**

| Column | Type | Description |
|---|---|---|
| id | uuid PK | |
| proposal_type | varchar(20) | `parameter` / `prompt` / `pair_config` |
| target_table | varchar(50) | `strategy_params`, `pair_config`, dll |
| target_pk | varchar(100) | mis. `pair=BTC/USDT` |
| diff | jsonb | `{"rsi_oversold": {"old": 32, "new": 28}, ...}` |
| reason | text | Hasil debat Hermes Council yang menjustifikasi |
| backtest_result | jsonb | Sharpe, max_dd, win_rate dari validator |
| status | varchar(20) | `proposed` / `validated` / `rejected` / `approved` / `applied` / `rolled_back` |
| created_by | varchar(50) | `hermes_council` / `pattern_layer1` / `rl_layer3` / `manual` |
| approved_by | varchar(50) | `aru` saat 90 hari pertama, atau `auto` setelahnya |
| created_at | timestamptz | |
| applied_at | timestamptz | nullable |
| rolled_back_at | timestamptz | nullable |
| rollback_reason | text | nullable |

**`parameter_sync` worker logic:**

```python
# parameter_sync/worker.py (file baru, di bawah agents/parameter_sync/)
async def sync_loop():
    while True:
        # Ambil semua proposals yang approved tapi belum applied
        proposals = await axiom_db.fetch(
            "SELECT * FROM axiom_proposals WHERE status='approved' "
            "ORDER BY created_at LIMIT 5"
        )
        for p in proposals:
            try:
                await apply_proposal(p)
                await axiom_db.execute(
                    "UPDATE axiom_proposals SET status='applied', applied_at=now() WHERE id=$1",
                    p["id"]
                )
                # Insert ke parameter_versions untuk audit trail
                await axiom_db.execute(...)  # see DATABASE_SCHEMA.md
                # Notif crypto-bot to reload (Redis pub/sub)
                await redis.publish("axiom:param_changed", json.dumps({"proposal_id": str(p["id"])}))
            except Exception as e:
                await axiom_db.execute(
                    "UPDATE axiom_proposals SET status='failed', rollback_reason=$2 WHERE id=$1",
                    p["id"], str(e)
                )
        await asyncio.sleep(60)
```

### 3.3 Channel C: Code Rewrite via Git Commit (full self-modification)

Untuk perubahan **logic code** (mis. tambah indicator baru di `engine/rule_based.py`), workflow:

```
[axiom-brain] → generate diff (unified format) → write ke code_change_audit (status=proposed)
                     │
                     ▼
[validator]      → pylint + pytest + backtest 30d
                     │ pass?
                     ▼
[asura agent]    → safety review (no shell, no IO outside workspace, no removal of guards)
                     │ pass?
                     ▼
[Aru approval]   → /approve_code {change_id} via Telegram (90 hari pertama)
                     │
                     ▼
[axiom-brain]    → checkout branch axiom/auto/{date}/{change_id}
                     git apply diff
                     git commit -m "[axiom-auto] {description}"
                     git push origin axiom/auto/...
                     UPDATE code_change_audit (status=committed)
                     │
                     ▼
[parameter_sync] → git fetch origin axiom/auto/*
                     trigger crypto-bot rolling restart
                     │
                     ▼
[crypto-bot]     → exit current loop gracefully → restart → load new code
                     │
                     ▼
[auto_rollback]  → monitor 24 jam: PnL < baseline - 2σ?
                     │ ya?
                     ▼
                   git revert + restart crypto-bot
                   UPDATE code_change_audit (status=rolled_back)
```

**Whitelist file yang boleh axiom modifikasi via Channel C** (didefine di `ai_capabilities/whitelist.json`):

```json
{
  "code_files_writable": [
    "agents/crypto_bot/engine/rule_based.py",
    "agents/crypto_bot/brains/prompts/haiku_system.txt",
    "agents/crypto_bot/brains/prompts/sonnet_system.txt"
  ],
  "config_files_writable": [
    "agents/crypto_bot/config/strategy_params.json",
    "agents/crypto_bot/config/pairs.json"
  ],
  "code_files_forbidden": [
    "agents/crypto_bot/exchange/**",
    "agents/crypto_bot/security/**",
    "agents/crypto_bot/notifications/auth.py",
    "agents/crypto_bot/database/client.py",
    "agents/crypto_bot/database/models.py",
    "agents/crypto_bot/main.py"
  ]
}
```

→ Detail mekanisme dan safety: **[AI_CAPABILITIES.md](./AI_CAPABILITIES.md#layer-4-self-modifying-logic)**.

---

## 4. CONTRACT FORMAT — OBJEK YANG DI-EXCHANGE

### 4.1 Trade Event (dari crypto-bot ke axiom)

Saat trade open atau close, crypto-bot publish ke `axiom:bot_events`:

```json
{
  "type": "position_closed",
  "ts": 1751999999.123,
  "trade_id": "uuid-1234-...",
  "pair": "BTC/USDT",
  "side": "buy",
  "entry_price": 95234.5,
  "exit_price": 96120.0,
  "amount_usd": 4.26,
  "pnl_usd": 0.39,
  "pnl_pct": 0.93,
  "duration_seconds": 7800,
  "trigger_source": "haiku",
  "is_paper": true,
  "metadata": {
    "rsi_at_entry": 28.4,
    "atr_pct_at_entry": 1.32,
    "regime_at_entry": "trending",
    "news_urgency_at_entry": 0.3
  }
}
```

### 4.2 Pattern Discovery (dari axiom ke audit)

Saat axiom-pattern menemukan pola baru, INSERT ke `pattern_discoveries`:

```json
{
  "id": "uuid-...",
  "pattern_type": "iceberg_order_at_resistance",
  "discovered_at": "2026-04-27T10:23:11Z",
  "discovered_by": "pattern_layer1",
  "evidence_window_start": "2026-04-20",
  "evidence_window_end": "2026-04-27",
  "occurrences": 14,
  "precision": 0.71,
  "recall": 0.42,
  "expected_outcome": "price_reversal_within_30min",
  "recommendation": "add_inhibitor_rule_at_RSI>65_AND_orderbook_depth_ratio>2.5",
  "status": "candidate"
}
```

### 4.3 Parameter Proposal (dari axiom ke crypto-bot via DB)

```json
{
  "id": "uuid-...",
  "proposal_type": "parameter",
  "target_table": "strategy_params",
  "target_pk": "pair=ETH/USDT",
  "diff": {
    "rsi_oversold": {"old": 32, "new": 28},
    "stop_loss_pct": {"old": 2.2, "new": 1.8}
  },
  "reason": "Pattern P-2026-04-27-iceberg detected at ETH/USDT in last 7d, win_rate baseline 52% → projected 61% with tighter SL and earlier RSI threshold. Hermes Council unanimous approve.",
  "backtest_result": {
    "period_days": 30,
    "sharpe_old": 1.21,
    "sharpe_new": 1.48,
    "max_drawdown_old": 0.087,
    "max_drawdown_new": 0.061,
    "win_rate_old": 0.524,
    "win_rate_new": 0.613
  },
  "status": "validated",
  "created_by": "hermes_council",
  "created_at": "..."
}
```

### 4.4 Code Change Proposal

```json
{
  "id": "uuid-...",
  "change_type": "rule_addition",
  "target_file": "agents/crypto_bot/engine/rule_based.py",
  "diff_unified": "@@ -94,6 +94,12 @@\n         if ind[\"volume_ratio\"] >= 1.5:\n+        # Axiom-auto: news_urgency inhibitor (added 2026-04-27)\n+        # Source: pattern_discoveries[uuid-...] precision 0.71\n+        if rule_result.get(\"news_urgency\", 0) > 0.85:\n+            return self._signal(\"hold\", 0.0, \"axiom_inhibitor\",\n+                                f\"news_urgency_too_high_{news_urgency:.2f}\")\n",
  "reason": "...",
  "validation_logs": "pylint: pass | pytest: 47 passed, 0 failed | backtest_30d: sharpe 1.21→1.39, max_dd 8.7%→7.2%",
  "asura_review": "pass: no shell exec, no file IO outside engine/, no removal of existing guards",
  "status": "approved",
  "branch_name": "axiom/auto/2026-04-27/news-inhibitor",
  "git_commit_sha": "..."
}
```

---

## 5. OBSERVABILITY & DEBUGGING

### 5.1 Log Aggregation

Semua container mount `./logs:/app/logs` (atau `/bot/logs` untuk crypto-bot). Per-service log file:

```
/root/axiom_core/logs/
├── orchestrator.log         (axiom-brain)
├── ares.log                 (axiom-brain pattern submodule)
├── bridge.log               (axiom-bridge)
├── thanatos.log             (axiom-thanatos)
├── telegram.log             (axiom-telegram)
├── pattern.log              (axiom-pattern, NEW)
├── consensus.log            (axiom-consensus, NEW)
├── parameter_sync.log       (cryptobot_param_sync, NEW)
└── cryptobot/
    ├── main.log             (cryptobot_main aggregate)
    ├── signal_generator.log
    ├── rule_based.log
    ├── haiku_brain.log
    ├── sonnet_brain.log
    ├── opus_brain.log
    ├── order_manager.log
    ├── circuit_breaker.log
    ├── news_fetcher.log
    └── telegram.log
```

### 5.2 Healthcheck Endpoints

| Service | Endpoint | Apa yang dicek |
|---|---|---|
| cryptobot_main | `GET /health` | DB ping + Redis ping + Bybit ping (in PAPER mode bisa fail) |
| cryptobot_main | `GET /status` | capital, pairs aktif, bot_paused state |
| axiom_nginx | `GET /health` | always 200 (nginx alive) |
| n8n | `GET /healthz` | n8n internal |

Container healthcheck di docker-compose:
```yaml
cryptobot_main:
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
    interval: 30s
    timeout: 5s
    retries: 3
    start_period: 60s  # boot time tolerance
```

### 5.3 Runbook Saat Sistem Down

**Crypto-bot tidak responding (Telegram diam, no trade dalam 1+ jam):**

```bash
# 1. Cek container status
docker ps -a | grep crypto

# 2. Lihat last logs
docker logs --tail 200 cryptobot_main

# 3. Cek health endpoint
curl -i http://localhost:8000/health

# 4. Cek redis flags (mungkin paused/circuit breaker)
docker exec axiom_redis redis-cli get shared:bot_paused
docker exec axiom_redis redis-cli get shared:circuit_breaker_tripped

# 5. Jika paused tanpa alasan jelas, unpause
docker exec axiom_redis redis-cli del shared:bot_paused

# 6. Restart container jika perlu (state di Postgres aman)
docker-compose restart cryptobot_main
```

**Axiom council tidak respond ke command Telegram:**

```bash
# 1. Cek axiom-brain container
docker logs --tail 200 axiom_brain

# 2. Cek redis queue length (mungkin stuck)
docker exec axiom_redis redis-cli llen axiom:command_queue

# 3. Cek koneksi OpenRouter (mungkin rate limit)
docker exec axiom_brain python -c "import os; from openai import OpenAI; c = OpenAI(api_key=os.getenv('OPENROUTER_API_KEY'), base_url='https://openrouter.ai/api/v1'); print(c.models.list().data[:3])"

# 4. Restart axiom-brain
docker-compose restart axiom_brain
```

**Database lambat / connection exhausted:**

```bash
# 1. Cek connection count di pgbouncer
docker exec axiom_pgbouncer psql -h localhost -p 6432 -U pgbouncer pgbouncer -c "SHOW POOLS;"

# 2. Cek slow queries di Postgres
docker exec axiom_db psql -U aru_admin -d cryptobot_db -c \
  "SELECT pid, now()-query_start AS duration, query FROM pg_stat_activity WHERE state='active' ORDER BY duration DESC LIMIT 10;"

# 3. Kill long-running query (use with caution)
docker exec axiom_db psql -U aru_admin -d cryptobot_db -c "SELECT pg_cancel_backend({pid});"
```

---

## 6. AUTH & SECRETS FLOW

### 6.1 Secrets Required

`.env` di root `/root/axiom_core/` (chmod 600, owner root):

```env
# === Bybit ===
BYBIT_API_KEY=...
BYBIT_API_SECRET=...
BYBIT_TESTNET=false  # but PAPER_TRADE controls actual paper mode

# === Anthropic (crypto-bot) ===
ANTHROPIC_API_KEY=...
ANTHROPIC_SPENDING_LIMIT=30

# === OpenRouter (axiom) ===
OPENROUTER_API_KEY=...

# === Telegram (DUA TOKEN) ===
TELEGRAM_BOT_TOKEN_AXIOM=...
TELEGRAM_BOT_TOKEN_CRYPTOBOT=...
TELEGRAM_CHAT_ID=...  # Aru's numeric chat_id, sama untuk kedua bot

# === Database ===
DB_HOST=axiom_pgbouncer  # via pooler, BUKAN langsung axiom_db
DB_PORT=6432
DB_NAME_AXIOM=axiom_memories
DB_NAME_CRYPTOBOT=cryptobot_db
DB_USER_AXIOM=axiom_user
DB_PASSWORD_AXIOM=...
DB_USER_CRYPTOBOT=cryptobot_user
DB_PASSWORD_CRYPTOBOT=...
DB_USER_OBSERVER=readonly_observer
DB_PASSWORD_OBSERVER=...

# === Redis ===
REDIS_URL=redis://:${REDIS_PASSWORD}@axiom_redis:6379
REDIS_PASSWORD=...

# === n8n ===
N8N_USER=aru009
N8N_PASSWORD=...
WEBHOOK_URL=http://axiom_n8n:5678/webhook/

# === Bot Behavior ===
PAPER_TRADE=true
INITIAL_CAPITAL=213
BOT_TIMEZONE=Asia/Jakarta
DAILY_TARGET_PCT=3.0  # turunkan dari 9.1% per Konflik 10

# === Auth (crypto-bot dashboard) ===
BOT_PIN_HASH=...

# === Frontend ===
FRONTEND_URL=  # kosong jika di-serve dari nginx VPS

# === VPS ===
VPS_IP=...

# === Backup ===
BACKBLAZE_B2_KEY_ID=...
BACKBLAZE_B2_APP_KEY=...
BACKBLAZE_B2_BUCKET=axiom-backups
```

### 6.2 Per-Service Secret Access

Tiap service hanya akses subset secret yang relevan via env_file dengan filter (atau lebih aman: pakai docker secret atau external secret manager).

Untuk MVP, semua service load `.env` lengkap (acceptable untuk single-tenant), tapi:
- Crypto-bot **tidak boleh** akses `OPENROUTER_API_KEY`, `TELEGRAM_BOT_TOKEN_AXIOM`
- Axiom **tidak boleh** akses `ANTHROPIC_API_KEY`, `BOT_PIN_HASH`, `TELEGRAM_BOT_TOKEN_CRYPTOBOT`

Solusi MVP: dua file `.env.axiom` & `.env.cryptobot` di-mount per service.

---

## 7. RACE CONDITIONS & EDGE CASES

| Scenario | Risk | Mitigation |
|---|---|---|
| Axiom apply parameter saat crypto-bot baca | Inconsistent param mid-cycle | parameter_sync hold lock pada `strategy_params` row, crypto-bot pakai `SELECT ... FOR SHARE` (gentle lock) |
| Aru issue `/pause` via 2 bot bersamaan | Race write Redis flag | Pakai `SETNX` + TTL, idempotent |
| Opus weekly run vs Hermes Council weekly run di waktu sama | Double LLM cost | Schedule berbeda: Opus Sun 00:00 WIB, Council Sun 04:00 WIB (after Opus result available) |
| Axiom propose param + Aru manual edit DB bersamaan | Manual changes lost | Trigger `BEFORE UPDATE` di `strategy_params` log ke `parameter_versions` (siapapun penulisnya) |
| Auto-rollback fire saat patch baru saja apply | Loss of new patch + state inconsistency | Lock 1-jam grace period setelah apply sebelum rollback monitor mulai |
| Telegram bot down → Aru tidak bisa approve patch | Patch mandek di status `validated` | Fallback approval via dashboard frontend dengan PIN auth |

---

## 8. VERSIONING & BACKWARD COMPATIBILITY

- **Schema migration**: `migrations/{N}_{name}.sql` di `agents/crypto_bot/database/migrations/` — naik nomor urut, tidak boleh edit migration lama
- **API versioning**: jika crypto-bot expose REST API ke axiom (jarang), prefix `/api/v1/...` dari awal. Breaking change → bump ke `/api/v2/`
- **Event schema**: pakai `version` field di setiap event payload (`{"type": "...", "version": 1, ...}`). Consumer ignore unknown version dengan log warning
- **Config**: jangan rename existing key di `.env.example` — deprecate dulu, baru remove di major version

---

## CURRENT STATE

**Last sync:** 2026-04-27

- ✅ 3 channel intervensi (Redis flag, DB proposal, git commit) terdokumentasi
- ✅ Schema event payload terdefinisi
- ✅ Postgres LISTEN/NOTIFY trigger SQL siap
- ✅ Redis pub/sub channel terdefinisi
- ✅ Healthcheck strategy mapped
- ✅ Runbook untuk 3 skenario down sudah ada
- ⏳ File `agents/observability/event_listener.py` di axiom-brain: **belum dibangun** (Phase 3)
- ⏳ File `agents/parameter_sync/worker.py`: **belum dibangun** (Phase 3)
- ⏳ File `agents/crypto_bot/utils/event_publisher.py`: **belum dibangun** (Phase 2-3, butuh PR ke crypto-bot repo)
- ⏳ Postgres trigger `notify_trade_inserted`: **belum** ditambahkan ke `init.sql`
- ⏳ Per-service env file split (`.env.axiom`, `.env.cryptobot`): belum diimplementasi, MVP pakai shared `.env`

---

## NEXT ACTION

**Untuk Claude Code:**

1. **JANGAN auto-build** file yang belum ada (event_listener, worker, publisher) — itu task Phase 2-3, butuh approval Aru.

2. Tambahkan **trigger SQL** ke schema cryptobot_db (akan dibangun bersamaan dengan Phase 1 setup):

```sql
-- File: agents/crypto_bot/database/migrations/001_axiom_observability.sql
CREATE OR REPLACE FUNCTION notify_trade_inserted() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('trade_inserted', json_build_object(
        'trade_id', NEW.id, 'pair', NEW.pair, 'side', NEW.side,
        'amount_usd', NEW.amount_usd, 'opened_at', NEW.opened_at
    )::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trades_after_insert AFTER INSERT ON trades
FOR EACH ROW EXECUTE FUNCTION notify_trade_inserted();

-- Repeat for bot_events table
CREATE OR REPLACE FUNCTION notify_event_inserted() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify('event_inserted', json_build_object(
        'event_id', NEW.id, 'event_type', NEW.event_type, 'severity', NEW.severity
    )::text);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER bot_events_after_insert AFTER INSERT ON bot_events
FOR EACH ROW EXECUTE FUNCTION notify_event_inserted();
```

→ Migration ini **belum boleh apply** sampai Phase 2 (setelah crypto-bot di-clone ke VPS), karena butuh akses ke schema `cryptobot_db`.

3. Lanjut ke **[DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md)** untuk pelajari schema lengkap.

4. Update CURRENT STATE saat ada perubahan kontrak.
