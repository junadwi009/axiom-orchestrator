# **STRATEGIC PORTFOLIO & COMPOUNDING TRACKER (V3.1 \- OMNISCIENCE)**

**Sovereign:** Aru (aru009) | **Target Kedaulatan:** $10,000 | **Mode:** Hyper-Compressed Paper Trade

## **HUKUM COMPOUNDING & RISK GATING (KAI'S LEDGER)**

Untuk mencapai $10.000 dalam 30-45 Hari, Ares dan Kai diwajibkan mencetak **Daily Compounding \~9.1%**.

* **Modal Awal Dasar:** $213 (Tersinkronisasi absolut dengan INITIAL\_CAPITAL pada .env).  
* **Drawdown Guillotine:** Batas toleransi penurunan dari saldo puncak adalah **15%**. Jika tersentuh, aliran modal dihentikan secara sepihak oleh Kai dan perdagangan dibekukan.

## **PROTOKOL EKSEKUSI ARES (V3 OPTIMIZED)**

* **Order Book Sniper:** Ares wajib menganalisis *Liquidity Gap* (Bid/Ask Spread) sebelum mengeksekusi order. Koin dengan likuiditas kosong akan ditolak untuk mencegah *Slippage*.  
* **Zero-Latency Execution:** Sinyal yang tervalidasi akan dikirim melalui openclaw\_bridge (\< 1ms) langsung ke Bybit V5 API menggunakan *Redis BLPOP*.

## **ALOKASI SEKTORAL & DYNAMIC ALPHA HUNTING**

Alokasi ini tidak lagi statis. Ares diizinkan memindahkan bobot persentase secara dinamis berdasarkan data *Trending* yang disuplai oleh n8n.

| ID | Sektor / Kategori | Aset Utama (Contoh) | Alokasi Maksimal | Target Win-Rate |
| :---- | :---- | :---- | :---- | :---- |
| **C1** | The Foundation | BTC, ETH, SOL | 20% | 92.4% |
| **C2** | AI & DePIN Infra | TAO, FET, RNDR | 20% | 89.5% |
| **C3** | DeFi & Modular | TIA, UNI, AAVE | 15% | 88.7% |
| **C4** | DYNAMIC ALPHA (n8n) | *Trending Coins \< Rank 500* | **35%** | **Variabel** |
| **C5** | Frontier & Memes | PEPE, WIF | 10% | 82.6% |

**Aturan Khusus C4 (Dynamic Alpha):**

Sektor C4 adalah "Ruang Kosong" yang dikhususkan untuk menampung sinyal *real-time* dari n8n (*CoinGecko Trending Scraper*). Ares akan menggunakan porsi 35% ini murni untuk melakukan *High-Frequency Scalping* pada koin apa pun yang sedang viral hari itu, asalkan lolos verifikasi *Liquidity Gap*.

**Audit Asura:** Khusus untuk sektor C5 (Memes), risiko diturunkan secara paksa menjadi maksimal 1.5% per *trade* untuk menangkis volatilitas sampah. Cindy (C.I.N.D.Y Noir) dilarang beroperasi di portofolio ini.