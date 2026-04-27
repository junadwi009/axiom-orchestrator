# Axiom Core × Crypto-Bot

**Status:** Integrated planning complete — Ready for Claude Code to bootstrap (Phase 1 / Milestone M1).
**Owner:** Aru (`@aru009`)
**VPS Target:** Contabo Cloud VPS 30 NVMe (4 vCPU / 12 GB RAM / 200 GB) — Ubuntu 24.04 LTS
**Submodule:** [`agents/crypto_bot`](https://github.com/junadwi009/crypto-bot)

---

## Apa Itu Sistem Ini

Dua sistem otonom yang saling melengkapi, **bukan parent-child**:

| Sistem        | Peran        | Stack                                                | Tujuan                                                                 |
|---------------|--------------|------------------------------------------------------|------------------------------------------------------------------------|
| **axiom**     | Brain / Guru | AutoGen multi-agent (Hermes 70B via OpenRouter)      | Pattern recognition, anomaly detection, pengajaran ke crypto-bot      |
| **crypto-bot**| Trader / Murid | FastAPI + asyncio (Anthropic Haiku/Sonnet/Opus)    | Eksekusi trading otonom di Bybit (paper → live setelah validasi R10) |

`axiom` mengamati `crypto-bot` lewat **3 channel komunikasi** (lihat [`INTEGRATION_GUIDE.md`](./INTEGRATION_GUIDE.md)) dan secara bertahap mengajarkan parameter, prompt, dan code yang lebih baik via **patch proposal workflow** (whitelist file dengan auto-validator + manual approval 90 hari pertama).

---

## Dokumentasi (urutan baca wajib)

| Urutan | File                                                       | Untuk Apa                                                              |
|--------|------------------------------------------------------------|------------------------------------------------------------------------|
| 1      | [`CLAUDE_INSTRUCTIONS.md`](./CLAUDE_INSTRUCTIONS.md)       | Hard rules R1-R10, milestone M1-M4, urutan baca dokumen lain          |
| 2      | [`ARCHITECTURE.md`](./ARCHITECTURE.md)                     | Filosofi sistem, 11-container Docker stack, alokasi resource VPS      |
| 3      | [`INTEGRATION_GUIDE.md`](./INTEGRATION_GUIDE.md)           | 3 channel A/B/C, patch proposal workflow, runbook 3 down-scenario     |
| 4      | [`DATABASE_SCHEMA.md`](./DATABASE_SCHEMA.md)               | Skema 2 database, 5 role, hypertable TimescaleDB, migrasi Supabase    |
| 5      | [`AI_CAPABILITIES.md`](./AI_CAPABILITIES.md)               | Layer 1-4 AI (pattern → anomaly → RL → self-modifying)                |
| 6      | [`DEVELOPMENT_ROADMAP.md`](./DEVELOPMENT_ROADMAP.md)       | Phase 1-4 dengan ETA, deliverables, exit criteria                     |
| 7      | [`MIGRATION_GUIDE.md`](./MIGRATION_GUIDE.md)               | Render → VPS Contabo, asyncpg port, nginx + Let's Encrypt + UFW       |

> Tiap file diakhiri `## CURRENT STATE` + `## NEXT ACTION` — dipakai sebagai persistent memory untuk Claude Code.

---

## Quick Start — Local Dev

### Prereq
- Docker Desktop (Windows) atau Docker Engine + Compose plugin (Ubuntu)
- Git
- 8 GB RAM minimum di mesin lokal (untuk full stack 11 containers)
- Credentials siap: OpenRouter, Anthropic, Bybit testnet, 2 token Telegram, chat_id

### Bootstrap (Ubuntu / WSL)
```bash
chmod +x setup_local.sh
./setup_local.sh
```

### Bootstrap (Windows PowerShell)
```powershell
pwsh -ExecutionPolicy Bypass -File .\setup_local.ps1
```

Script akan:
1. Cek prerequisite tools.
2. Generate 8 password random ke `.env` + `credentials.txt`.
3. Generate `pgbouncer/userlist.txt` dengan md5 hash yang benar.
4. Init git submodule `agents/crypto_bot/`.
5. `docker compose up -d --build`.
6. Healthcheck loop sampai semua container ready.

**Lalu buka `.env`** dan isi manual field berikut (script tidak men-generate):
- `OPENROUTER_API_KEY`
- `ANTHROPIC_API_KEY`
- `BYBIT_API_KEY` / `BYBIT_API_SECRET`
- `TELEGRAM_BOT_TOKEN_AXIOM`
- `TELEGRAM_BOT_TOKEN_CRYPTOBOT`
- `TELEGRAM_CHAT_ID`
- `BOT_PIN_HASH`

Restart stack: `docker compose down && docker compose up -d`.

---

## Endpoint Lokal

| Service         | URL                          | Auth                       |
|-----------------|------------------------------|----------------------------|
| Crypto-bot API  | http://localhost:8000        | PIN unlock via `/auth/login` |
| n8n dashboard   | http://localhost:5678        | basic auth dari `.env`     |
| PgBouncer       | localhost:6432               | per-user role              |
| Postgres direct | localhost:5432               | hanya untuk admin tasks    |
| Redis           | localhost:6379               | password dari `.env`       |

---

## Stack Diagram (high-level)

```
                        Telegram Bot AXIOM    Telegram Bot CRYPTOBOT
                                |                       |
                          [ axiom_telegram ]      [ cryptobot_main ]
                                |                       |
   +----------- axiom-network (Docker bridge) -----------+
   |                                                     |
[ axiom_brain ]<--Channel A (Redis pub/sub)-->[ axiom_bridge ]
   |                                                     |
[ axiom_pattern (Layer 1-2) ]                            |
   |                                                     |
[ axiom_consensus (Hermes vs Opus) ]                     |
   |                                                     |
   v                                                     v
[ axiom_pgbouncer ] -----> [ axiom_db (Postgres+Timescale) ]
                                  |
                  +---------------+---------------+
                  |                               |
            axiom_memories                  cryptobot_db
            (8 + 3 tables)                  (12 tables, 4 hypertables)
```

Detail lengkap: [`ARCHITECTURE.md`](./ARCHITECTURE.md#docker-stack).

---

## Operational Parameters (locked-in)

| Parameter            | Nilai           | Sumber Keputusan        |
|----------------------|-----------------|-------------------------|
| Initial capital      | $213            | crypto-bot inherits     |
| Daily target         | **3.0 %** (was 9.1%) | Konflik 10 → realistic, tunable up oleh AI |
| Drawdown guillotine  | 15 %            | crypto-bot circuit breaker |
| Paper-trade default  | `true`          | R10 — wajib validasi >30 hari sebelum live |
| Telegram bots        | 2 separate      | Konflik 3               |
| Database             | 1 cluster, 2 DB | Konflik 2 (ii)          |
| Submodule strategy   | git submodule   | Konflik 8               |
| Exchange lib         | pybit + ccxt    | Konflik 5               |
| Frontend             | nginx static    | Konflik 6 (B)           |
| Deployment           | Docker Compose  | Konflik 7               |
| Auto-approve window  | OFF for 90 days | R5 patch proposal       |

---

## Kontrak Hard untuk Claude Code

Sebelum melakukan APAPUN, **wajib** baca [`CLAUDE_INSTRUCTIONS.md`](./CLAUDE_INSTRUCTIONS.md) dari atas sampai bawah, lalu cek `## CURRENT STATE` untuk milestone aktif.

Singkatnya:
- **R1** — Tidak ada asumsi diam. Tanya kalau ragu.
- **R5** — Patch proposal untuk semua perubahan di whitelist code (`engine/rule_based.py`, `brains/prompts/*`, `config/strategy_params.json`, `config/pairs.json`).
- **R6** — `crypto-bot` tetap autonomous; axiom hanya observer + teacher.
- **R7** — Database adalah single source of truth. Jangan duplikat state.
- **R10** — Paper trade default. Live trading hanya setelah validasi 30 hari + manual approval.

Folder yang **DILARANG dimodifikasi** oleh axiom auto-rewrite (R5):
- `agents/crypto_bot/exchange/`
- `agents/crypto_bot/security/`
- `agents/crypto_bot/auth.py`
- `agents/crypto_bot/database/client.py`
- `agents/crypto_bot/main.py`

---

## CURRENT STATE

- ✅ Architecture decided (10/10 conflicts resolved)
- ✅ Documentation complete (7 markdown files)
- ✅ Docker compose + init SQL scripts ready
- ✅ Setup scripts (Windows + Ubuntu) ready
- ⏳ **Pending:** First bootstrap run on Aru's machine (M1)
- ⏳ Pending: Render → VPS migration (M2)
- ⏳ Pending: AI Layer 1-2 implementation (M3)
- ⏳ Pending: Self-improving loop activation (M4)

## NEXT ACTION

Untuk Aru:
1. Clone repo ini ke local: `git clone <axiom-orchestrator-url>`.
2. Run `./setup_local.sh` (Ubuntu) atau `.\setup_local.ps1` (Windows).
3. Isi credentials manual di `.env`.
4. Verifikasi `docker compose ps` semua healthy.
5. Buka `http://localhost:8000/health` → harus return `{"status":"ok"}`.
6. Tag tahap M1 selesai → lanjut ke [`MIGRATION_GUIDE.md`](./MIGRATION_GUIDE.md) untuk M2.

Untuk Claude Code:
- Baca semua 7 file dokumentasi.
- Verifikasi `agents/crypto_bot/` benar-benar git submodule (ada `.git` file, bukan folder).
- Sebelum modify file apapun, cek apakah masuk whitelist R5.
- Setiap selesai task, update `## CURRENT STATE` di file relevan.
