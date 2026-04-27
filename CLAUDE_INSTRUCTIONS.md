# CLAUDE_INSTRUCTIONS.md — ENTRY POINT WAJIB

> **Status:** ACTIVE | **Owner:** Aru (aru009) | **Last Sync:** auto-updated by axiom on every dev session
> **File ini WAJIB dibaca oleh Claude Code SEBELUM file lain di repo ini.**
> **Jika kamu Claude Code dan baru saja membuka repo ini, BERHENTI di sini, baca seluruh file ini, lalu lanjutkan ke urutan baca yang ditetapkan di bawah.**

---

## 🛑 RULE NOMOR SATU — PROTOKOL BERHENTI

Sebelum kamu menulis SATU baris kode pun atau menjalankan SATU perintah pun, kamu wajib:

1. Membaca seluruh isi file ini
2. Membaca semua file `.md` di root sesuai urutan di section "URUTAN BACA WAJIB"
3. Membaca `core_memory/00_SOVEREIGN_SOUL.md` dan `core_memory/01_Sovereign_Core.md`
4. Memverifikasi `## CURRENT STATE` di setiap file `.md` masih akurat dengan kondisi nyata di repo (cek struktur folder, isi `.env.example`, container yang berjalan)
5. Jika ada **perbedaan** antara CURRENT STATE di dokumen dan kondisi nyata → **BERHENTI, lapor ke Aru, JANGAN diam-diam memperbaiki**

---

## 📚 URUTAN BACA WAJIB

Kamu **HARUS** membaca file dalam urutan ini, tanpa boleh skip atau membaca paralel:

```
1. CLAUDE_INSTRUCTIONS.md   ← kamu sedang di sini
2. ARCHITECTURE.md          ← peta sistem, harus dipahami dulu
3. INTEGRATION_GUIDE.md     ← kontrak antar komponen
4. DATABASE_SCHEMA.md       ← schema lengkap PostgreSQL+TimescaleDB
5. AI_CAPABILITIES.md       ← spesifikasi kapabilitas AI yang harus dibangun
6. DEVELOPMENT_ROADMAP.md   ← tahapan & milestone
7. MIGRATION_GUIDE.md       ← prosedur migrasi Render → VPS Contabo
```

Setelah selesai membaca semuanya, baru kamu boleh mengeksekusi task. Jika user/Aru meminta task spesifik (misal "fix bug di ares_analyzer"), tetap baca **minimum CLAUDE_INSTRUCTIONS + ARCHITECTURE + file relevan**.

---

## ⚠️ HARD RULES — TIDAK BOLEH DILANGGAR DALAM KONDISI APAPUN

### R1. Jangan Pernah Berasumsi Diam-Diam
Jika ada ambiguitas, **BERHENTI dan tanya Aru via chat**. Jangan tulis kode dengan asumsi "mungkin maksudnya begini." Asumsi diam-diam adalah pengkhianatan terhadap integritas sistem.

### R2. Konflik = Wajib Dilaporkan, Bukan Diselesaikan Sendiri
Jika kamu menemukan konflik antar dokumen, antar file kode, atau antara dokumen dan kode → **BERHENTI dan lapor**. Jangan pilih salah satu sisi.

### R3. Setiap Keputusan Arsitektur Baru = Wajib Konfirmasi
Jika task user butuh keputusan yang **belum tercatat di file `.md` manapun di root**, kamu wajib bertanya dulu. Setelah Aru menjawab, kamu wajib **mengupdate file `.md` yang relevan** dengan keputusan tersebut sebelum lanjut implementasi.

### R4. Jangan Pernah Sentuh Folder Whitelist Larangan
Berikut folder/file yang **HARAM** kamu modifikasi tanpa instruksi eksplisit dari Aru:

| Folder/File | Alasan |
|---|---|
| `.env`, `.env.local`, `.env.production` | Berisi kredensial. Kamu boleh baca template `.env.example` saja |
| `agents/crypto_bot/security/` | Auth, secret_guard, log_sanitizer — domain Risk Officer |
| `agents/crypto_bot/exchange/` | Eksekusi order → bug di sini = kebocoran modal |
| `agents/crypto_bot/notifications/auth.py` | PIN auth Telegram — keamanan |
| `agents/crypto_bot/database/client.py` | Layer DB — perubahan harus via DB Engineer |
| `core_memory/01_Sovereign_Core.md` | Hukum tertinggi sistem |
| `data/postgres_data/`, `data/redis_data/` | Data persistensi → backup-only |
| File apapun di branch `main`/`master` tanpa PR | Wajib lewat branch `axiom/auto/{date}` atau `feature/{name}` |

Modifikasi file di whitelist larangan **hanya** boleh dilakukan setelah Aru memberi izin eksplisit dalam chat dengan kalimat seperti *"Ya, saya izinkan kamu modifikasi {file}"*.

### R5. Setiap Perubahan Kode Crypto-bot = Lewat Patch Proposal Workflow
Axiom **TIDAK BOLEH** push kode langsung ke `agents/crypto_bot/` di branch `main`. Workflow yang sah:

1. Axiom analisis → tulis proposal ke tabel `code_change_audit` (status: `proposed`)
2. Auto-validator: pylint pass + pytest pass + backtest 30 hari pass → status `validated`
3. Safety review oleh Asura agent (rule-based) → status `safety_passed`
4. Selama 90 hari pertama: butuh approval Aru lewat Telegram bot/dashboard → status `approved`
5. Apply via git commit ke branch `axiom/auto/{YYYY-MM-DD}/{patch-id}` → trigger `parameter_sync` worker
6. Auto-rollback monitor 24 jam: jika PnL turun >2σ → revert otomatis, status → `rolled_back`

Detail mekanisme → lihat **[AI_CAPABILITIES.md](./AI_CAPABILITIES.md#layer-4-self-modifying-logic)**.

### R6. Crypto-bot adalah Produk Otonom, Bukan Executioner
Per keputusan arsitektur final (lihat **[ARCHITECTURE.md](./ARCHITECTURE.md#identitas-komponen)**):
- crypto-bot **memutuskan sendiri** kapan BUY/SELL/HOLD lewat pipeline `rule_based → Haiku → Sonnet`
- axiom **TIDAK** mengirim sinyal trading langsung ke crypto-bot
- axiom hanya mengubah **parameter**, **prompt**, dan **kode** crypto-bot via R5
- Jangan tulis kode di axiom yang push ke `bybit_execution_queue` Redis (legacy queue dari arsitektur lama, sudah deprecated)

### R7. Database = Source of Truth Tunggal
Semua state penting **wajib** persistent ke PostgreSQL+TimescaleDB lokal. Redis hanya untuk:
- Ephemeral state (flags, rate limit counter, session)
- Message queue antar process
- Hot cache (TTL ≤ 5 menit)

Jika ragu di mana menyimpan data baru → default ke Postgres. Lihat **[DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md)**.

### R8. Logging Wajib, Print Haram
Semua output runtime wajib via Python `logging` dengan format standar:
```python
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("logs/{module_name}.log", encoding="utf-8")
    ]
)
```
**Jangan pernah** pakai `print()` di kode produksi — ia tidak masuk ke log file & tidak bisa di-grep oleh Thanatos.

### R9. Setiap Operasi Mutating ke Database = Audit Trail Wajib
Setiap kali axiom UPDATE/INSERT ke `strategy_params`, `pair_config`, atau tabel critical lain, **wajib** ada baris baru di `parameter_versions` (untuk parameter) atau `code_change_audit` (untuk kode). Tanpa audit trail, perubahan dianggap ilegal & wajib di-rollback.

### R10. Live Trading Hanya Setelah Backtest 90 Hari & Paper Trade 14 Hari
`PAPER_TRADE=false` hanya boleh diset oleh Aru manual via SSH ke VPS. Claude Code **TIDAK BOLEH** mengubah variable ini di file `.env` atau di runtime. Threshold migrasi paper → live:
- Min 90 hari backtest pass dengan Sharpe ≥ 1.5, max drawdown ≤ 15%
- Min 14 hari paper trade aktif dengan win rate ≥ 55%, avg PnL/trade ≥ 0.3%
- Aru explicit approval di Telegram

---

## 🤝 CARA BERINTERAKSI DENGAN AXIOM & CRYPTO-BOT

### Saat Aru meminta task baru
1. Identifikasi: ini task untuk **axiom** atau **crypto-bot** atau **integrasi**?
2. Baca file `.md` yang relevan (minimum: ARCHITECTURE + file yang spesifik domain task)
3. Cek `## CURRENT STATE` di file relevan
4. Konfirmasi dengan Aru jika task akan menyentuh whitelist larangan (R4)
5. Implementasi lewat branch baru: `feature/{nama-task}` (bukan langsung di main)
6. Update `## CURRENT STATE` & `## NEXT ACTION` di file `.md` yang terdampak
7. Commit dengan format: `[axiom|cryptobot|infra] {ringkasan}: {detail}`

### Saat menyentuh kode crypto-bot
- Selalu cek apakah perubahan harus lewat **patch proposal workflow (R5)** atau bisa langsung (jarang — hanya untuk infra fix yang tidak terkait strategi)
- Jika langsung: branch `feature/cryptobot-{task}`, PR harus tag `@aru009` untuk review
- Jika via patch proposal: tulis `axiom_proposals` row, tunggu validator + approval

### Saat menemukan bug
1. Reproduce dulu — jangan trust user report tanpa konfirmasi
2. Tulis test case yang fail dengan bug current → fix → test pass
3. Jika bug di crypto-bot's strategy logic → masuk ke patch proposal (R5)
4. Jika bug infrastruktur → langsung fix dengan test, log di `bot_events` table

### Saat panic / sistem down
- Cek **[INTEGRATION_GUIDE.md](./INTEGRATION_GUIDE.md#observability--debugging)** untuk runbook
- Selalu pakai `docker logs -f {container_name}` sebelum restart
- Jangan panic restart — ada sistem state di Redis yang akan hilang
- Aktifkan `bot_paused=1` di Redis dulu, lalu investigate

---

## ✅ DEFINISI "DONE" PER MILESTONE

### Milestone M1 — Local Setup Validated (Hari 1)
- [ ] Python venv lokal aktif untuk axiom-orchestrator (Windows + Ubuntu version dokumentasinya)
- [ ] crypto-bot ter-clone sebagai git submodule di `agents/crypto_bot/` (BUKAN flat copy)
- [ ] `docker-compose up -d` di lokal Ubuntu (atau WSL2 untuk Windows) menjalankan: `axiom_db`, `axiom_redis`, `axiom_n8n` minimal
- [ ] `python orchestrator.py` jalan tanpa error import & terkoneksi ke axiom_db + axiom_redis
- [ ] `cd agents/crypto_bot && python main.py` jalan dengan `PAPER_TRADE=true`, terkoneksi ke local Postgres (bukan Supabase)
- [ ] Telegram bot axiom dan crypto-bot keduanya respon `/status` di chat masing-masing
- [ ] **DONE bila**: kedua proses berjalan minimum 30 menit tanpa crash, healthcheck endpoint `/health` di crypto-bot return 200, axiom log "Sidang Dewan dimulai" muncul setelah trigger Telegram

### Milestone M2 — Migrasi Render → VPS Contabo (Hari 2-3)
- [ ] VPS Contabo Cloud VPS 30 NVMe (atau VPS 20 NVMe minimum) ter-provision dengan Ubuntu 24.04 LTS
- [ ] UFW firewall setup (allow ssh, allow 5678 n8n, allow 8000 crypto-bot health, allow 80/443 nginx)
- [ ] Docker + docker-compose v2 + git terinstall
- [ ] Folder `/root/axiom_core/` setup dengan submodule `agents/crypto_bot` ter-clone
- [ ] Database migration script: dump schema dari Supabase → load ke local Postgres → verify row counts match
- [ ] `.env` di VPS terisi semua kredensial
- [ ] `docker-compose up -d --build` semua container UP & healthy
- [ ] Telegram notif "Bot started" muncul untuk kedua bot
- [ ] DNS/IP redirection: jika ada subdomain pointing ke Render, pindahkan ke VPS IP
- [ ] **DONE bila**: 7×24 jam paper trade berjalan tanpa restart, Render service di-suspend (bukan deleted dulu untuk rollback option)

### Milestone M3 — Axiom AI Capabilities Layer 1+2 (Hari 4-10)
- [ ] Pattern recognition module aktif: anomaly detection di `ares_market_scans` running tiap 5 menit
- [ ] `pattern_discoveries` table populated dengan minimum 50 pola unik dalam 7 hari
- [ ] Volatility regime classifier deploy (HMM 3-state)
- [ ] Cross-exchange divergence monitor aktif (axiom pakai ccxt untuk Bybit + Binance + OKX)
- [ ] News sentiment shock alert terhubung ke `bot_paused` flag (auto-pause saat shock)
- [ ] Dual-brain consensus (Opus + Hermes Council) running weekly
- [ ] **DONE bila**: minimum 1 cycle weekly evaluation selesai dengan kedua brain, hasil tersimpan di `consensus_log` dengan agreement decision yang sah

### Milestone M4 — Self-Improving Loop Aktif (Hari 11-30)
- [ ] Layer 3 (RL parameter tuning) deploy dengan Thompson sampling
- [ ] Min 10 parameter rewrite proposal dari axiom → 7+ approved & applied → 5+ menunjukkan improvement vs baseline
- [ ] Layer 4 (self-modifying logic) di mode "human-in-the-loop": min 3 patch proposed, validated, approved, applied tanpa rollback
- [ ] Auto-rollback monitor terbukti bekerja (minimum 1 patch sengaja dirilis dengan flaw → ter-revert otomatis dalam 24 jam)
- [ ] Dashboard frontend nampilkan side-by-side: keputusan crypto-bot vs evaluasi axiom + diff parameter terbaru
- [ ] **DONE bila**: sistem berjalan otonom 14 hari berturut-turut tanpa intervensi manual, win rate naik minimum 3 percentage points dari baseline

---

## 📐 STANDARDS TEKNIS YANG WAJIB DIIKUTI

### Kode Python
- Python 3.11.x untuk crypto-bot (sesuai `render.yaml` PYTHON_VERSION pin)
- Python 3.10+ untuk axiom (sesuai `Dockerfile.brain`)
- Style: PEP 8, max line length 100 (longgar dari 79 default karena nama fungsi panjang di domain trading)
- Type hints **wajib** untuk public methods
- Async/await untuk I/O di crypto-bot (sudah pakai); axiom boleh sync (AutoGen tidak fully async)
- Linter: `ruff` (cepat) + `mypy` (gradual typing — wajib untuk file di `engine/`, `database/`)

### Git
- Branch protection di `main`: butuh 1 review + CI green
- Conventional commits: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`
- Squash merge untuk feature branches
- Tags untuk release: `v{MAJOR}.{MINOR}.{PATCH}` semantic versioning

### Docker
- Multi-stage builds untuk production images
- `.dockerignore` wajib (jangan copy `.git`, `__pycache__`, `node_modules`)
- Healthcheck di setiap service
- Resource limits (memory, cpus) di production compose

### Logging
- Format: `%(asctime)s [%(levelname)s] %(name)s: %(message)s`
- Level INFO default, DEBUG hanya saat dev
- Rotasi log via `logging.handlers.RotatingFileHandler` max 100MB per file, 5 files retention
- Sensitive data sanitization sebelum log (gunakan `agents/crypto_bot/security/log_sanitizer.py`)

### Testing
- Unit test wajib untuk: `engine/`, `database/`, `brains/` (mock LLM API)
- Coverage minimum 70% untuk file di `engine/` dan `database/`
- Integration test untuk patch proposal workflow (E2E: propose → validate → apply → rollback)
- Backtest framework di `backtesting/runner.py` adalah ground truth untuk strategy evaluation

---

## 🆘 CARA MEMINTA BANTUAN AKUR

Jika kamu (Claude Code) stuck atau ragu:

1. **Quote masalah spesifik** ke Aru — jangan abstract
2. **Tunjukkan konflik** dengan side-by-side dari dua sumber
3. **Tawarkan 2-3 opsi** dengan trade-off masing-masing
4. **Jangan pilih sendiri** — biarkan Aru putuskan
5. Jika sudah dapat keputusan → **update file `.md` yang relevan** sebelum implement

Format pertanyaan yang baik:
```
Saya stuck di {task}. Konflik: {file A} bilang X, {file B} bilang Y.
Opsi yang saya lihat:
  (A) ... pros: ... cons: ...
  (B) ... pros: ... cons: ...
  (C) ... pros: ... cons: ...
Rekomendasi saya: opsi B karena ...
Tunggu keputusan Aru sebelum lanjut.
```

---

## 🔁 LIVING DOCUMENTATION — INI BUKAN README STATIS

File-file `.md` di root bukan dokumentasi pasif. Mereka adalah **memori aktif** sistem. Setiap kali axiom atau Claude Code:
- Membuat keputusan arsitektur baru → **update ARCHITECTURE.md**
- Mengubah schema → **update DATABASE_SCHEMA.md**
- Menambah kapabilitas AI → **update AI_CAPABILITIES.md**
- Melakukan migrasi step besar → **update MIGRATION_GUIDE.md**
- Menyelesaikan milestone → **update DEVELOPMENT_ROADMAP.md** (centang checkbox + update CURRENT STATE)

Tanpa update ini, file `.md` jadi **misleading** dan sesi pengembangan berikutnya akan basecamp di asumsi yang salah → debt menumpuk.

**Setiap commit yang menyentuh code arsitektur juga wajib menyentuh minimum satu `.md` file**, kecuali commit purely fix typo/comment.

---

## CURRENT STATE

**Tanggal sync terakhir:** 2026-04-27
**Source of truth:** Aru (manual), Claude Code (automated update tiap session)

- ✅ Keputusan arsitektur 10 konflik utama: terdokumentasi (lihat tiap file `.md`)
- ✅ Database stack: PostgreSQL 16 + TimescaleDB (extension) + Redis 7
- ✅ Crypto-bot identity: **autonomous product** dengan rule_based → Haiku → Sonnet pipeline (BUKAN executioner)
- ✅ Axiom role: **AI Developer Team** — observer, evaluator, parameter rewriter, code-change proposer
- ✅ Telegram: 2 bot terpisah (axiom-bot & cryptobot-bot, dua token)
- ✅ LLM: Anthropic API (di crypto-bot) + OpenRouter Hermes (di axiom council) — dual-brain consensus weekly
- ✅ Exchange: pybit primary (eksekusi), ccxt di axiom (multi-exchange intel)
- ✅ Frontend: React+Vite di-deploy ke VPS yang sama via nginx static
- ✅ Deployment: Docker Compose only (deploy.sh PM2 deprecated)
- ✅ Submodule: `agents/crypto_bot/` adalah git submodule ke `git@github.com:junadwi009/crypto-bot.git`
- ⏳ Local setup belum tervalidasi — M1 milestone pending
- ⏳ VPS Contabo belum di-provision — M2 milestone pending
- ⏳ Anthropic API key untuk crypto-bot, OpenRouter key untuk axiom: belum konfirmasi tersedia

---

## NEXT ACTION

**Untuk Claude Code di sesi pengembangan berikutnya, eksekusi tepat dalam urutan:**

1. **Baca file ini sampai akhir** + 6 file `.md` lain di urutan baca wajib (≈ 30 menit)
2. **Verifikasi CURRENT STATE** di setiap file masih cocok dengan kondisi nyata folder
3. **Check git status** & branch — pastikan ada di branch yang benar (jangan kerja di main langsung)
4. **Eksekusi M1 (Local Setup Validated)** sesuai checklist di atas:
   - Jalankan `setup_local.ps1` (Windows) atau `setup_local.sh` (Ubuntu) → lihat **[DEVELOPMENT_ROADMAP.md](./DEVELOPMENT_ROADMAP.md#phase-1-local-setup--integration-validation)** Phase 1
   - Validasi: `docker ps` → minimum 3 container UP (db, redis, n8n)
   - Validasi: kedua Telegram bot respon
5. **Setelah M1 done**, update CURRENT STATE di file ini (`✅ Local setup validated`) lalu lanjut ke M2

Jika kamu ragu di langkah manapun → STOP, konsultasi dengan Aru lewat chat.

---

> *"Asumsi diam-diam adalah pengkhianatan. Konflik wajib dilaporkan. Kedaulatan dipertahankan via dokumentasi yang hidup."*
