# AI_CAPABILITIES.md — KAPABILITAS AI YANG AKAN DIBANGUN

> **Status:** AUTHORITATIVE | **Owner:** Aru (aru009)
> File ini definisikan **kapabilitas AI yang HARUS dibangun di axiom** untuk membentuk loop self-improvement.
> Target: axiom secara progresif jadi lebih pintar dari rule-based dan dari Claude Sonnet di crypto-bot.

→ Prerequisite: **[ARCHITECTURE.md](./ARCHITECTURE.md)**, **[INTEGRATION_GUIDE.md](./INTEGRATION_GUIDE.md)**, **[DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md)** sudah dibaca.

---

## 1. FILOSOFI PEMBANGUNAN AI

Per Konflik 10: target harian diturunkan dari 9.1% menjadi **3%**, tapi sistem harus **mampu mengenali pola yang melebihi kalkulasi manusia** sehingga bisa naik kapan saja. Ini bukan kontradiksi — ini permission grant: konservatif by default, agresif by AI signal.

Empat prinsip non-negotiable:

1. **Defense in depth**: setiap layer punya "kill switch" individual (Redis flag), tidak ada single dependency yang kalau gagal mati semuanya
2. **Validation gates**: tidak ada parameter/code change yang masuk production tanpa lolos backtest minimum 30 hari
3. **Human-in-the-loop default ON** untuk 90 hari pertama; setelah ≥30 successful auto-changes, baru boleh switch ke fully autonomous
4. **Auditable**: setiap keputusan AI (pattern discovery, parameter rewrite, code patch) tercatat di database dengan timestamp, evaluator, alasan, dan outcome — bisa di-replay kapan saja

---

## 2. LAYER 1 — PATTERN RECOGNITION

**Tujuan**: deteksi pola pergerakan harga & volume yang **tidak terlihat oleh indicator klasik** RSI/MACD/BB yang dipakai crypto-bot. Output → `pattern_discoveries` table.

### 2.1 Komponen yang Akan Dibangun

#### A) Time-series Anomaly Detector
- **Algoritma**: Isolation Forest (sklearn) atau Local Outlier Factor (LOF)
- **Input**: feature vector dari `ares_market_scans` per pair, window 60 menit (120 row × 30s scan)
  - Features: log-return 5/15/30/60-min, RSI 14h, ATR%, volume_ratio, volatility_spread, liquidity_gap
- **Output**: anomaly_score per timestamp, threshold 95-percentile
- **Frekuensi run**: tiap 5 menit, batch process 12 hour rolling window
- **File**: `agents/axiom_pattern/anomaly_detector.py` (BARU, di container `axiom_pattern`)
- **Dependency**: scikit-learn, numpy, pandas

```python
# Sketch implementation
from sklearn.ensemble import IsolationForest
import asyncpg

class TimeSeriesAnomalyDetector:
    def __init__(self, contamination=0.05):
        self.model = IsolationForest(
            contamination=contamination,
            random_state=42,
            n_estimators=200,
            max_samples="auto"
        )

    async def fit_predict_window(self, pair: str, hours: int = 12):
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT scan_timestamp, current_price, volatility_spread,
                       liquidity_gap, rsi_14h, volume_24h_usd
                FROM ares_market_scans
                WHERE symbol = $1
                  AND scan_timestamp > now() - INTERVAL '%s hours'
                ORDER BY scan_timestamp ASC
            """ % hours, pair)

        features = self._extract_features(rows)  # log returns, ratios, etc
        anomalies = self.model.fit_predict(features)
        scores = self.model.decision_function(features)

        # Save anomalous timestamps to pattern_discoveries
        for i, (anom, score) in enumerate(zip(anomalies, scores)):
            if anom == -1 and score < -0.15:  # strong anomaly
                await self._record_anomaly(pair, rows[i], score)
```

#### B) Order Book Pattern Miner
- **Tujuan**: deteksi pola seperti **iceberg orders** (large hidden orders), **spoofing** (fake orders cancelled), **absorption** (large market orders absorbed without price move)
- **Input**: snapshot bid/ask top-20 levels tiap 30 detik (perlu schema baru)
- **Schema baru di `cryptobot_db`** — perlu di-add:

```sql
CREATE TABLE orderbook_snapshots (
    id              BIGSERIAL,
    pair            VARCHAR(20) NOT NULL,
    captured_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    best_bid_price  NUMERIC(18, 8),
    best_ask_price  NUMERIC(18, 8),
    bids_top20      JSONB NOT NULL,  -- [[price, qty], [price, qty], ...]
    asks_top20      JSONB NOT NULL,
    spread_bps      INT,
    bid_volume_total NUMERIC(20, 4),
    ask_volume_total NUMERIC(20, 4),
    PRIMARY KEY (captured_at, pair, id)
);
SELECT create_hypertable('orderbook_snapshots', 'captured_at',
    chunk_time_interval => INTERVAL '1 day');
SELECT add_compression_policy('orderbook_snapshots', INTERVAL '7 days');
SELECT add_retention_policy('orderbook_snapshots', INTERVAL '60 days');
```

- **Producer**: crypto-bot's `engine/orderbook_capturer.py` (BARU) — call Bybit `/v5/market/orderbook` setiap 30 detik untuk active pairs, INSERT ke tabel
- **Consumer**: axiom_pattern container, modul `orderbook_miner.py`:
  - **Iceberg detection**: orderbook level dengan qty besar yang persisten >5 snapshot → kandidat iceberg
  - **Spoofing**: large order yang muncul lalu hilang dalam <2 snapshot → kandidat spoof
  - **Absorption**: market order >X% notional volume tanpa price move proportional
- **Output**: insert ke `pattern_discoveries` dengan `pattern_type` sesuai

#### C) Volume Profile Analyzer
- **Library**: `vectorbt` (sudah ada di crypto-bot deps, tapi pakai di axiom)
- **Output**: per pair daily — Point of Control (POC), Value Area High (VAH), Value Area Low (VAL)
- **Use case**: support/resistance levels yang lebih kuat dari fixed Fibonacci. Di-feed sebagai context tambahan untuk Sonnet brain via `axiom:pattern_alert:{pair}` Redis key
- **File**: `agents/axiom_pattern/volume_profile.py`

#### D) Cross-Exchange Divergence Detector
- **Library**: ccxt (sudah ada di axiom deps)
- **Logic**:
  1. Setiap 60 detik, fetch ticker untuk pairs aktif dari Bybit, Binance, OKX, Bitget
  2. Hitung price spread max-min di tiap timestamp dalam basis points
  3. Jika spread >20 bps konsisten >3 menit untuk pair tertentu → arbitrage signal candidate
  4. Insert ke `cross_exchange_signals` dengan flag `arbitrage_opp=true`
  5. Notifikasi ke axiom-brain via Redis: pertimbangkan adjust threshold strategi (mis. tighten spread filter di rule_based)
- **File**: `agents/axiom_pattern/cross_exchange_monitor.py`

### 2.2 Pipeline Pattern Discovery → Validation → Promotion

```
[axiom_pattern container, schedule via apscheduler]
  ├── 5 min: TimeSeriesAnomalyDetector run for all active pairs
  ├── 5 min: Iceberg/Spoofing/Absorption miner from orderbook_snapshots
  ├── Daily 00:00: Volume Profile compute
  └── 60 sec: Cross-exchange divergence scan

  ↓ (semua write ke pattern_discoveries dengan status='candidate')

[axiom_brain, daily 02:00]
  └── Validation pass:
       - Setiap pola harus dibuktikan dengan minimum 10 occurrence
       - Hitung precision: dari 10+ occurrence, berapa % yang outcome sesuai expected_outcome (mis. price reverse dalam 30 menit)
       - Hitung recall: dari semua kasus mirip di historical 30d, berapa % yang ter-detect
       - Pola dengan precision ≥0.65 & recall ≥0.30 → promote ke status='validated'

[axiom_brain (Hermes Council), saat ada >5 validated patterns]
  └── Promotion pass:
       - Council debat: "Pattern X dengan precision 0.71, recall 0.40 — apakah cukup actionable untuk dijadikan rule baru?"
       - Jika konsensus YA → generate proposal di axiom_proposals dengan diff yang menambah inhibitor/enabler rule
       - Jika kontroversi → tunggu lebih banyak data
       - Jika konsensus TIDAK → status='rejected'
```

### 2.3 Output → Influence ke Crypto-Bot

Pola yang validated akan mempengaruhi crypto-bot via:

- **Channel A (Redis flag)**: untuk pola time-sensitive (mis. "regime baru saja chaos onset"), set `axiom:pattern_alert:regime=chaos` → crypto-bot rule_based check ini sebagai inhibitor
- **Channel B (parameter rewrite)**: untuk pola yang stabil (mis. "BTC iceberg pattern reliable di RSI 65-72"), generate proposal yang adjust `rsi_overbought` dari 70 → 68
- **Channel C (code change)**: untuk pola yang butuh logic baru (mis. "absorption pattern butuh check spread+volume kombinasi"), generate code patch ke `engine/rule_based.py`

→ Detail mekanisme: lihat **[INTEGRATION_GUIDE.md](./INTEGRATION_GUIDE.md#mekanisme-intervensi-axiom)** section 3.

---

## 3. LAYER 2 — ANOMALY DETECTION (Kondisi Pasar Ekstrem)

**Tujuan**: deteksi kondisi pasar yang **akan** menyebabkan loss besar — circuit breaker yang lebih cerdas dari sekadar drawdown 15%.

### 3.1 Komponen

#### A) Volatility Regime Classifier (HMM 3-state)
- **Algoritma**: Hidden Markov Model 3-state ("calm", "trending", "chaos") via library `hmmlearn`
- **Input**: rolling volatility (ATR%) dan return autocorrelation untuk BTC sebagai market-wide proxy
- **Frekuensi**: trained weekly dari 90-day data, inference real-time tiap 5 menit
- **Output**: insert state ke `pattern_discoveries` dengan `pattern_type='regime_state'`, dan set Redis: `axiom:current_regime=chaos|trending|calm`
- **Action saat regime=chaos terdeteksi**:
  - Set `shared:bot_paused=1` dengan TTL 60 menit
  - Telegram alert ke Aru: "⚠️ Regime CHAOS detected. Bot paused for 60 min. Override with /resume."
- **File**: `agents/axiom_pattern/regime_classifier.py`

```python
from hmmlearn import hmm
import numpy as np

class RegimeClassifier:
    def __init__(self):
        self.model = hmm.GaussianHMM(n_components=3, covariance_type="full",
                                      n_iter=100, random_state=42)
        self.state_labels = {0: "calm", 1: "trending", 2: "chaos"}  # ditentukan post-training

    def train(self, returns_array, vol_array):
        X = np.column_stack([returns_array, vol_array])
        self.model.fit(X)
        # Mapping state index ke label berdasarkan covariance terbesar = chaos
        # ... logic to determine which state is which

    def predict(self, recent_features):
        return self.state_labels[self.model.predict(recent_features)[-1]]
```

#### B) Liquidity Collapse Detector
- **Logic**: jika `volume_ratio < 0.3` (rolling 30-min vs 24h-avg) di **>50% pairs aktif simultaneously** → flash crash imminent
- **Run frekuensi**: 5 min
- **Action**: set `shared:circuit_breaker_tripped=1` dengan reason="liquidity_collapse_detected"
- **File**: `agents/axiom_pattern/liquidity_monitor.py`

#### C) Correlation Spike Alert
- **Logic**: BTC-ETH-SOL korelasi pearson rolling 1h. Normal ~0.7. Saat naik >0.95 → semua aset bergerak satu blok = sentiment-driven panic
- **Action**: kurangi `position_size_multiplier` di Redis: `axiom:override_position_size=0.5` (50% dari normal). Crypto-bot's order_manager check ini saat compute amount_usd
- **Run frekuensi**: 1 min

#### D) News Sentiment Shock
- **Input**: `news_items` table, filter `haiku_urgency > 0.85 AND haiku_sentiment < -0.7`
- **Logic**: jika ≥3 news shock dalam 30 menit window → freeze new orders 60 menit
- **Action**: set `shared:bot_paused=1` TTL 3600s, alasan="news_shock"
- **File**: `agents/axiom_pattern/news_shock_monitor.py`

### 3.2 Visualisasi & Tuning

Setiap detector punya dashboard Grafana (optional, Phase 3+) atau minimum log JSON ke `logs/pattern.log` dalam format searchable. Aru bisa tune threshold via env var:

```env
PATTERN_REGIME_CHAOS_THRESHOLD_VAR=2.5
PATTERN_LIQUIDITY_COLLAPSE_THRESHOLD=0.3
PATTERN_CORRELATION_SPIKE_THRESHOLD=0.95
PATTERN_NEWS_SHOCK_COUNT_THRESHOLD=3
PATTERN_NEWS_SHOCK_WINDOW_MIN=30
```

### 3.3 Validation: Backtest pada Historical Crashes

Sebelum deploy ke production, **wajib** backtest tiap detector pada minimum 3 historical event:
- LUNA crash (Mei 2022)
- FTX collapse (Nov 2022)
- COVID crash (Mar 2020)

Detector dianggap valid jika:
- Mendeteksi event ≥1 jam sebelum drawdown 5% di BTC
- False positive rate ≤2 alert per bulan saat market normal

---

## 4. LAYER 3 — REINFORCEMENT LEARNING (Parameter Optimization)

**Tujuan**: axiom belajar **parameter mana yang menghasilkan PnL tinggi di regime tertentu** tanpa human intervention. Outputnya: `axiom_proposals` dengan parameter changes.

### 4.1 Pendekatan Bertahap

#### Tahap 3a: Multi-Armed Bandit (MAB) untuk Parameter Tuning
- **Algoritma**: Thompson Sampling
- **State**: tuple (pair, regime) — mis. ("BTC/USDT", "trending")
- **Arms**: kombinasi parameter values yang diizinkan, mis.:
  - `rsi_oversold ∈ {28, 30, 32, 34}`
  - `rsi_overbought ∈ {66, 68, 70, 72}`
  - `stop_loss_pct ∈ {1.5, 1.8, 2.0, 2.2}`
  - Total = 4×4×4 = 64 arms per (pair, regime)
- **Reward**: realized PnL per trade dalam window 24 jam setelah parameter change
- **Update**: posterior Beta distribution per arm berdasarkan reward observed
- **Library**: implementasi custom Thompson sampling (no library karena ringan), atau pakai `mabwiser`
- **File**: `agents/axiom_rl/thompson_bandit.py`
- **Frekuensi sampling**: setiap awal cycle baru (30 menit interval), pilih arm dengan posterior sample tertinggi sebagai parameter aktif

```python
# Sketch
import numpy as np

class ThompsonBandit:
    """One bandit per (pair, regime) tuple."""
    def __init__(self, n_arms: int):
        self.alpha = np.ones(n_arms)  # success counts
        self.beta = np.ones(n_arms)   # failure counts

    def sample_arm(self) -> int:
        samples = np.random.beta(self.alpha, self.beta)
        return int(np.argmax(samples))

    def update(self, arm: int, reward: float):
        # reward in [0, 1] — convert PnL to bounded reward
        # ...
        if reward > 0.5:
            self.alpha[arm] += reward
        else:
            self.beta[arm] += (1 - reward)
```

**Safety**: setiap arm yang dipilih wajib lolos sanity check sebelum apply ke production:
- Tidak boleh `stop_loss_pct < 1.0` (hard cap)
- Tidak boleh `take_profit_pct > 5.0` (avoid overoptimization)
- Tidak boleh combo yang violated risk/reward ratio < 1.5

#### Tahap 3b: Offline RL via Conservative Q-Learning (CQL)
- **Tujuan**: belajar policy optimal dari **historical trade data** tanpa risiko di-deploy ke production
- **Algoritma**: Conservative Q-Learning (CQL) — variant dari Q-learning yang penalize Q-value untuk action di luar dataset (avoid distributional shift)
- **State**: 20-dimensional vector (RSI, ATR%, volume_ratio, regime, news_urgency, current_drawdown, cash_pct, time_of_day, day_of_week, BTC_correlation, dll)
- **Action**: discrete {hold, buy, sell, scale_up, scale_down}
- **Library**: `d3rlpy` (offline RL framework, Python)
- **Training**: weekly, dari rolling 90-day historical trades
- **Evaluation**: pada held-out 7 days, hitung:
  - Off-policy evaluation (FQE: Fitted Q Evaluation) untuk estimate expected PnL
  - Compare dengan baseline (current rule-based + Sonnet pipeline)
- **File**: `agents/axiom_rl/cql_trainer.py`

**Catatan**: Tahap 3b adalah research-grade. Output bukan langsung apply ke production, tapi **direkomendasikan ke Hermes Council** sebagai input untuk debat. Council yang putuskan apakah translate ke parameter/code change.

#### Tahap 3c: Online Safety Constraint
Setiap proposed parameter change dari MAB atau CQL **wajib lolos validator**:

1. **Backtest 30-day walk-forward**:
   - Split data 30 hari ke 6 fold (5 hari per fold)
   - Train pada fold 1-5, test pada fold 6
   - Hitung Sharpe, max_dd, win_rate
   - Jika Sharpe baru > Sharpe lama × 1.05 AND max_dd baru < max_dd lama → pass
2. **Risk constraint**:
   - max_drawdown_simulated ≤ 12% (lebih ketat dari hard limit 15%)
   - Position sizing tidak boleh > 5% capital per trade
3. **Statistical significance**:
   - Min 50 trades dalam window evaluasi (avoid overfitting ke <50 trades)
   - p-value untuk null hypothesis "params lama = params baru" < 0.05 via paired t-test

Validator file: `agents/axiom_rl/proposal_validator.py`. Output → update field `backtest_result` di `axiom_proposals`.

### 4.2 Failure Mode Analysis

| Failure mode | Mitigation |
|---|---|
| MAB stuck di arm tertentu (no exploration) | Thompson sampling natural exploration via prior; tambah epsilon-greedy backup (5% chance pilih random arm) |
| CQL overfitting ke lucky history (mis. bull market 2024) | Regularization + walk-forward; minimum window 90d untuk variety regime |
| Validator pass tapi live performance buruk (selection bias) | Staged rollout: apply ke 1 pair dulu (BTC), monitor 7 hari, baru promote ke pair lain |
| Parameter change agresif menyebabkan tail risk | Hard caps di constraint validation; auto-rollback jika 24h post-apply PnL < baseline-2σ |

---

## 5. LAYER 4 — SELF-MODIFYING LOGIC (Code Rewrite)

**Tujuan**: axiom secara otonom **menulis ulang kode** crypto-bot — bukan sekadar tweak parameter. Ini layer paling berbahaya, paling banyak guardrail.

→ Lihat juga **[INTEGRATION_GUIDE.md](./INTEGRATION_GUIDE.md#channel-c-code-rewrite-via-git-commit-full-self-modification)** untuk mekanisme git commit & rollback.

### 5.1 Scope yang Diizinkan

**Whitelist file yang BOLEH dimodifikasi axiom (di `agents/crypto_bot/`):**
1. `engine/rule_based.py` — boleh tambah/hapus rule
2. `brains/prompts/haiku_system.txt` — boleh edit system prompt
3. `brains/prompts/sonnet_system.txt` — boleh edit system prompt
4. `config/strategy_params.json` — boleh tambah field baru
5. `config/pairs.json` — boleh tambah/hapus pair (dengan trigger pengaman)

**Forbidden list (HARAM modifikasi):**
- `exchange/*.py` — eksekusi order
- `security/*.py` — auth, sanitization
- `notifications/auth.py` — Telegram PIN auth
- `database/client.py`, `database/models.py` — DB layer
- `main.py` — entry point
- `requirements.txt` — dependency lock
- `.env*`
- File `.py` apapun di luar whitelist yang impact lebih dari 1 method

### 5.2 Workflow Patch Proposal Lengkap

```
┌─────────────────────────────────────────────────────────────────┐
│  Trigger: pattern_discoveries with status='validated' AND        │
│           recommendation = 'add_inhibitor_rule_at_X'             │
└────────────────┬────────────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 1: Hermes Council Debate                                   │
│  axiom-consensus initiate council session                        │
│  Topik: "Implement pattern recommendation X as code change?"     │
│  Output: konsensus (apply/reject) + draft diff                   │
└────────────────┬────────────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 2: Generate Unified Diff                                   │
│  axiom_brain pakai LLM (Sonnet 4.6) untuk:                       │
│    - Read target file                                             │
│    - Generate patch dengan format unified diff                    │
│    - Ensure patch applies cleanly (dry run via `git apply --check`)│
│  Insert ke code_change_audit (status='proposed')                 │
└────────────────┬────────────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 3: Auto-Validator                                          │
│  3a. Apply patch in temp branch (axiom/auto/{date}/{id})         │
│  3b. Run pylint → must pass                                       │
│  3c. Run pytest (only affected modules) → must pass               │
│  3d. Run backtest 30-day walk-forward → Sharpe/dd improvement     │
│  Update status='validated' jika semua pass                       │
│  Update status='rejected' jika ada yang gagal + log alasan        │
└────────────────┬────────────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 4: Asura Safety Review (rule-based)                        │
│  Asura agent run static analysis:                                │
│    - No `os.system()`, `subprocess.*`, `eval()`, `exec()`         │
│    - No file IO outside `agents/crypto_bot/` workspace            │
│    - No removal of existing safety guards (e.g. circuit breaker)  │
│    - No new external HTTP calls (whitelist Bybit/CryptoPanic only)│
│    - Diff scope < 100 lines (avoid massive refactor in one patch) │
│  Update status='safety_passed' jika clear                         │
│  Update status='rejected' jika ada violation + lock 7 hari        │
└────────────────┬────────────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 5: Human Approval (mandatory 90 hari pertama)              │
│  Telegram bot kirim ke Aru:                                      │
│    "🤖 Patch proposal {id}                                         │
│     File: engine/rule_based.py                                   │
│     Reason: {reason}                                             │
│     Backtest: Sharpe 1.21→1.39, max_dd 8.7%→7.2%                 │
│     Safety: passed                                               │
│     [Approve] [Reject] [View Diff]"                              │
│  Aru click "Approve" → /approve_code {id}                        │
│  Update status='approved'                                        │
│                                                                   │
│  SETELAH 90 HARI: jika ≥30 successful patches, mode beralih:     │
│  - Aru set `axiom:auto_approve_enabled=1` di Redis               │
│  - Patch yang lolos backtest ≥2σ improvement bisa auto-approve   │
└────────────────┬────────────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 6: Apply via Git                                           │
│  axiom_brain (atau axiom-consensus) execute:                     │
│    1. git checkout -b axiom/auto/{date}/{change_id}              │
│    2. git apply diff                                              │
│    3. git commit -m "[axiom-auto] {short description}"            │
│    4. git push origin axiom/auto/...                              │
│    5. (NO direct merge ke main)                                   │
│  Trigger cryptobot_param_sync untuk cherry-pick & reload          │
│  Update status='committed' + git_commit_sha                      │
└────────────────┬────────────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 7: Rolling Restart Crypto-Bot                              │
│  cryptobot_param_sync:                                           │
│    1. Set Redis flag `shared:bot_pause_for_reload=1`              │
│    2. Wait 60s untuk pending orders selesai                       │
│    3. Send SIGTERM ke cryptobot_main → graceful shutdown          │
│    4. docker-compose restart cryptobot_main                       │
│    5. Wait healthcheck `/health` 200 OK                           │
│    6. Unset Redis flag                                           │
│  Update status='applied' + applied_at                            │
└────────────────┬────────────────────────────────────────────────┘
                 ▼
┌─────────────────────────────────────────────────────────────────┐
│  STEP 8: Auto-Rollback Monitor (24h grace period)                │
│  Cron tiap jam selama 24 jam post-apply:                         │
│    - Compute realized PnL since apply                             │
│    - Compare dengan baseline (PnL average 7-day pre-apply)        │
│    - Jika current < baseline - 2σ → trigger rollback             │
│  Rollback procedure:                                             │
│    1. git revert {commit_sha}                                     │
│    2. git push                                                    │
│    3. Restart crypto-bot                                          │
│    4. Telegram alert: "🚨 Patch {id} rolled back. PnL delta {x}%" │
│    5. Update status='rolled_back' + rollback_pnl_delta            │
└─────────────────────────────────────────────────────────────────┘
```

### 5.3 Trust Building Schedule

90-hari pertama: human-in-the-loop **wajib**. Aru approve setiap patch.

| Hari | Mode | Status |
|---|---|---|
| 1-90 | Mandatory human approval | Build trust |
| 91-180 | Auto-approve untuk patch yang ≥3σ improvement, manual untuk yang lebih rendah | Selective autonomy |
| 181+ | Auto-approve default ON, kill-switch via `axiom:auto_disabled=1` | Full autonomy with safety net |

**Trust earn-back**: jika auto-rollback terjadi >2× dalam 30 hari, mode revert ke mandatory human approval. Setelah 30 hari clean, baru bisa earn back ke selective.

---

## 6. AXIOM EDUCATES CRYPTO-BOT — THE LEARNING LOOP

```
crypto-bot trade decisions (pipeline rule_based → Haiku → Sonnet)
            │
            ▼
trades + bot_events (Postgres, hypertable)
            │
            ▼
[axiom_pattern, hourly]
  ├── Layer 1: pattern recognition di trades + ares_market_scans
  └── Layer 2: anomaly detection di market state
            │
            ▼
pattern_discoveries (status='candidate')
            │
            ▼ (validation)
pattern_discoveries (status='validated' jika precision ≥0.65)
            │
            ▼
[axiom_brain Hermes Council, daily]
  └── Debate: "Apa lesson dari pattern X?"
       Output verdict di axiom_evaluations
            │
            ▼
axiom_proposals (parameter/prompt/code change)
            │
            ▼ (validator + safety review)
axiom_proposals (status='validated' → 'safety_passed' → 'approved')
            │
            ▼
[parameter_sync OR git apply] → cryptobot_main reload
            │
            ▼
crypto-bot pakai parameter/prompt/code BARU
            │
            ▼ (24h grace period)
axiom monitor: PnL delta vs baseline
  ├── improvement → trust++ → patch jadi permanent
  └── degradation > 2σ → auto-rollback
            │
            ▼
Loop kembali ke top — pattern recognition di data baru post-apply
```

### 6.1 Contoh Konkret Lesson Learned

**Skenario:** 7 hari belakangan, BTC/USDT di-trade dengan rule_based → Haiku → Sonnet pipeline. Win rate 48%. Axiom analisa:

```
Step 1 (Layer 1 - pattern_discoveries):
  - 23 trades, 11 win, 12 loss
  - Pattern detected: "trades dengan news_urgency >0.7 saat regime=chaos →
    win rate 12.5% (1 dari 8)"
  - Pattern P-2026-04-27-NU-CHAOS, precision 0.875 untuk avoid

Step 2 (Layer 2 - validation):
  - Cross-check 30 hari historical: pattern muncul 31 kali, win rate avoid 28% (vs trade 14%)
  - Promotion ke validated

Step 3 (Hermes Council debate):
  - Violet: "Pattern jelas. Add inhibitor rule."
  - Asura: "Setuju. Risk reduction substantial."
  - Ares: "Tapi kita kehilangan 14% win rate trades juga. Net positive masih."
  - Eve: "Konsensus: implement sebagai inhibitor di rule_based.py"

Step 4 (Generate diff via Sonnet 4.6):
  Diff (unified):
    --- a/agents/crypto_bot/engine/rule_based.py
    +++ b/agents/crypto_bot/engine/rule_based.py
    @@ -94,6 +94,12 @@
            if ind["volume_ratio"] >= 1.5:
    +        # Axiom-auto: news_urgency inhibitor in chaos regime
    +        # Source: pattern_discoveries[P-2026-04-27-NU-CHAOS] precision 0.875
    +        regime = redis_client.get("axiom:current_regime")
    +        if (rule_result.get("news_urgency", 0) > 0.7 and regime == "chaos"):
    +            return self._signal("hold", 0.0, "axiom_inhibitor",
    +                                "news_urgency_high_in_chaos_regime")

Step 5 (Validator):
  - pylint: PASS
  - pytest: 47 passed, 0 failed
  - Backtest 30 hari walk-forward: Sharpe 1.21 → 1.39, max_dd 8.7% → 7.2%
  - Status: validated

Step 6 (Asura review):
  - No shell exec, no IO leak, no guard removal
  - Status: safety_passed

Step 7 (Telegram approval):
  Aru tap "Approve"
  - Status: approved

Step 8 (Apply):
  - Branch: axiom/auto/2026-04-27/news-chaos-inhibitor
  - Commit SHA: a3f2c8...
  - Crypto-bot restart, status applied

Step 9 (24h monitor):
  - PnL day-1 post-apply: +1.8% (baseline 7-day avg: +0.4%)
  - Improvement detected → no rollback
  - Patch jadi permanent setelah 24 jam
```

---

## 7. ROADMAP IMPLEMENTASI LAYER

→ Detail timeline: **[DEVELOPMENT_ROADMAP.md](./DEVELOPMENT_ROADMAP.md)**.

| Layer | Estimasi effort | Dependency |
|---|---|---|
| Layer 1A (Time-series anomaly) | 3-5 hari coding | M1 done, axiom_pattern container ready |
| Layer 1B (Order book miner) | 5-7 hari (butuh schema baru + producer di crypto-bot) | M2 done, capture loop deployed |
| Layer 1C (Volume profile) | 2-3 hari | M2 done |
| Layer 1D (Cross-exchange) | 3-5 hari | ccxt setup di axiom |
| Layer 2 (semua 4 detector) | 5-7 hari | Layer 1 done untuk dapat data feed |
| Layer 3a (Thompson MAB) | 3-5 hari | M2 + 30 hari trade data |
| Layer 3b (CQL offline RL) | 10-15 hari (research-grade) | 90 hari trade data |
| Layer 4 (self-modifying) | 7-10 hari + 90 hari trust building | Layer 1, 2, 3a done |

**Total realistic timeline ke full Layer 4 mature**: ~6 bulan dari M2.

---

## 8. METRICS & SUCCESS CRITERIA

### 8.1 Per-Layer Metrics

| Layer | Metric | Target |
|---|---|---|
| L1 anomaly | Pattern discovery rate | ≥10 unique patterns/week |
| L1 anomaly | Validation pass rate | ≥30% candidates jadi validated |
| L1 anomaly | False positive rate | ≤5 alert/day saat market normal |
| L2 regime | Detection lead time pre-crash | ≥30 menit |
| L2 regime | False positive rate | ≤2 alert/month |
| L3 MAB | Convergence time | ≤14 hari per (pair, regime) |
| L3 MAB | Improvement vs baseline | ≥5% Sharpe gain after convergence |
| L4 self-modify | Patch acceptance rate (validator+safety) | ≥40% |
| L4 self-modify | Rollback rate | ≤15% within 24h |
| L4 self-modify | Net PnL improvement after 30 patches | ≥3 percentage points win rate |

### 8.2 System-Level Success Criteria (90-hari mark)

- ✅ Daily target 3% achieved ≥70% trading days (paper or live)
- ✅ Max drawdown ≤12% (lebih ketat dari hard limit 15%)
- ✅ Sharpe ratio ≥1.5 (annualized, after costs)
- ✅ Min 5 patches axiom auto-approved & applied tanpa rollback
- ✅ Win rate naik dari baseline (50-55%) ke ≥58%
- ✅ Cost LLM total ≤$30/month (Anthropic + OpenRouter combined)

---

## CURRENT STATE

**Last sync:** 2026-04-27

- ✅ Spesifikasi 4 layer terdokumentasi lengkap
- ✅ Workflow patch proposal step-by-step terdefinisi
- ✅ Validation gates & safety constraints terdokumentasi
- ✅ Whitelist file untuk Channel C terdefinisi
- ✅ Trust building schedule (90 hari → 180 hari → full autonomous)
- ⏳ Container `axiom_pattern`, `axiom_consensus`: **belum** ada di docker-compose, akan dibangun di Phase 3
- ⏳ Module `agents/axiom_pattern/*.py`, `agents/axiom_rl/*.py`: **belum** ada
- ⏳ Tabel `orderbook_snapshots` di `cryptobot_db`: **belum** ada — perlu migration script
- ⏳ Fungsi `engine/orderbook_capturer.py` di crypto-bot: **belum** ada — perlu PR ke crypto-bot repo
- ⏳ Sebagian besar dari ini Phase 3-4 work, **bukan untuk dibangun sekarang**. Phase 1-2 fokus pada migrasi & integrasi dasar.

---

## NEXT ACTION

**Untuk Claude Code:**

1. **JANGAN langsung bangun module ML** — itu Phase 3+. Phase 1-2 fokus pada:
   - Validate local setup (M1)
   - Migrasi Render → VPS (M2)
   - Setup container `axiom_pattern` & `axiom_consensus` sebagai **placeholder dengan health endpoint** (return "not implemented" tapi container UP)

2. Saat siap masuk Phase 3 (setelah M2 done):
   - Mulai dari **Layer 1A (Time-series anomaly detector)** karena dependency paling sedikit
   - Test di paper trade environment selama 14 hari sebelum naik ke layer berikutnya
   - Update CURRENT STATE di file ini setelah tiap layer deploy

3. Untuk Layer 4: **JANGAN aktifkan** sampai minimum 60 hari Layer 1+2+3a stabil. Ini layer yang paling berbahaya — butuh trust foundation dari layer di bawahnya.

→ Lanjut ke **[DEVELOPMENT_ROADMAP.md](./DEVELOPMENT_ROADMAP.md)** untuk timeline dan milestone.
