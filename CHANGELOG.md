# AXIOM CHANGELOG — V4 FIXED

## Ringkasan Perbaikan dari Analisis Review

---

## 🐛 BUG FIXES

### `database_handler.py`
- **FIXED**: IndentationError fatal di method `save_knowledge()` — `print()` berada di luar method scope
- **FIXED**: `ON CONFLICT (id)` diganti menjadi `ON CONFLICT (entity_source, pattern_name)` sesuai unique constraint yang benar
- **ADDED**: Auto-reconnect jika koneksi PostgreSQL terputus (`_ensure_connection()`)
- **ADDED**: Try/except di setiap public method — tidak ada lagi crash silent
- **ADDED**: `get_trade_history()` untuk audit Kai & Asura

### `init.sql`
- **FIXED**: Tambah `CONSTRAINT uq_kb_source_pattern UNIQUE (entity_source, pattern_name)` — tanpa ini `ON CONFLICT` di database_handler tidak bisa berjalan
- **ADDED**: Tabel `trade_executions` untuk riwayat order nyata dari Executioner
- **ADDED**: Index tambahan pada kolom yang sering di-query

### `ares_analyzer.py`
- **FIXED**: Shadow intel yang sebelumnya **hardcoded string palsu** (misalnya "Latensi 0.08ms", "Rotasi 45 proxy") diganti dengan data pasar **NYATA**:
  - RSI 14h (Wilder method)
  - Volume 24h dalam USD
  - Persentase perubahan harga 24h
  - High/Low 24h
- **FIXED**: `calculate_slippage()` kini mengembalikan `(slippage, best_bid, best_ask)` tuple — data bid/ask tersedia untuk disimpan ke DB
- **ADDED**: `get_ohlcv_snapshot()` untuk data historis singkat

### `orchestrator.py`
- **FIXED**: JSON signal parser diganti dari string `.replace()` biasa menjadi **regex** — tidak bisa ditipu narasi LLM yang membungkus JSON
- **FIXED**: Field sinyal diseragamkan ke `size_usd` (bukan `amount`) agar cocok dengan yang dibaca `bot.py`
- **FIXED**: Prompt dewan kini menerima data **pasar nyata** dari Ares (RSI, volume, high/low) bukan string dekoratif palsu
- **ADDED**: `_process_pnl_feedback()` — membaca hasil trade dari Redis dan update Kai secara otomatis
- **ADDED**: Logging ke file `logs/orchestrator.log`
- **ADDED**: `HOLD_CONFIRMED` sebagai termination message kedua selain `EXECUTE_OPENCLAW`

### `bot.py` (Executioner)
- **FIXED**: Membaca field `size_usd` (sebelumnya membaca `amount` yang tidak pernah ada di sinyal Orchestrator → order selalu di-skip)
- **FIXED**: Kalkulasi amount koin menggunakan `exchange.amount_to_precision()` — tidak ada lagi floating point error
- **ADDED**: `_push_pnl_feedback()` — setelah order masuk, push notifikasi ke Redis queue `axiom_pnl_results` agar Kai bisa update feedback loop
- **ADDED**: Logging ke file `logs/executioner.log`

### `openclaw_bridge.py`
- **IMPROVED**: Logging standar ke file `logs/bridge.log`
- **MAINTAINED**: Retry strategy 3x dengan backoff tetap dipertahankan (sudah solid)

### `requirements.txt`
- **ADDED**: `psycopg2-binary==2.9.9` — tanpa ini `database_handler.py` crash saat import
- **ADDED**: `urllib3==2.1.0` eksplisit untuk retry di `openclaw_bridge.py`

### `docker-compose.yaml`
- **FIXED**: Tambah `healthcheck` pada service `db` dan `redis` — service lain tidak naik sebelum DB & Redis benar-benar siap
- **FIXED**: Mount volume `./logs:/app/logs` di semua service — log tersimpan persisten di host
- **ADDED**: Service `axiom-thanatos` untuk dead-letter queue monitoring
- **ADDED**: Service `axiom-telegram` sebagai container terpisah (sebelumnya tidak ada di compose)
- **FIXED**: `axiom-brain` command membuat folder `logs/` sebelum menjalankan Python

---

## 🆕 FITUR BARU

### `backtest.py` (Baru)
Framework backtesting lengkap menggunakan data historis OHLCV dari Bybit:
- Strategi: RSI + EMA Cross + ATR-based Stop Loss / Take Profit
- Mirror logika KaiBudgeting: drawdown guillotine, circuit breaker, position sizing
- Output: laporan konsol + file JSON di folder `logs/`
- Mode portfolio scan multi-simbol (`--portfolio`)
- Sharpe Ratio, Max Drawdown, Win Rate, Total Fees

```
# Cara pakai:
python backtest.py --symbol BTC/USDT --days 30 --timeframe 15m
python backtest.py --portfolio --days 30 --timeframe 15m
```

### `.env.example` (Baru)
Template lengkap semua environment variable yang dibutuhkan sistem.

---

## 📐 ALUR DATA SETELAH FIX

```
[Telegram] 
    ↓ pesan teks
[Redis: telegram_to_orchestrator]
    ↓ BLPOP
[Orchestrator V4]
    ├─ AresAnalyzer.get_market_pulse() → RSI, Volume, Slippage NYATA
    ├─ KaiBudgeting.calculate_position_size() → margin bersih + drawdown check
    ├─ 8 Agen AutoGen berdebat (dengan data nyata di prompt)
    └─ Regex JSON parser → signal {"action":"BUY","size_usd":4.26,...}
    ↓
[Redis: bybit_execution_queue]
    ↓ BLPOP
[Executioner / bot.py]
    ├─ Baca size_usd (FIXED dari 'amount')
    ├─ Hitung amount koin dengan amount_to_precision()
    ├─ create_market_order() → Bybit API
    └─ Push PnL result → Redis: axiom_pnl_results
    ↓
[Orchestrator._process_pnl_feedback()]
    └─ Kai.record_trade_result() → update consecutive_losses & peak_balance
```
