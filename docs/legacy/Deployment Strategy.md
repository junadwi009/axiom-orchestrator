# **DEPLOYMENT STRATEGY: SOVEREIGN AWAKENING (HYBRID EDITION)**

**Project:** AXIOM MYTHOS | **Owner:** Aru (aru009) | **Target:** Independent VPS (Contabo dll)

## **FASE 1: PERSIAPAN RAGA DI VPS**

1. **Akses Root:** Masuk ke VPS melalui SSH.  
2. **Pembersihan & Instalasi:** Pastikan Docker dan Git telah terpasang dengan versi terbaru.  
3. **Penciptaan Ruang Tahta & Persistensi Memori:**  
   mkdir \-p /root/axiom\_core  
   cd /root/axiom\_core

   \# WAJIB: Membuat folder untuk memori n8n dan PostgreSQL agar data tidak hilang  
   mkdir \-p data/postgres\_data data/n8n\_data core\_memory logs

   \# Memberikan izin agar Docker bisa menulis di folder tersebut  
   chmod \-R 777 data/

## **FASE 2: PENGGABUNGAN KEKUATAN (THE SUBMODULE BINDING \- SSH PROTOCOL)**

Ini adalah langkah krusial untuk menarik algojo eksekusi Anda ke dalam ekosistem AXIOM menggunakan jalur komunikasi terenkripsi yang mutlak (SSH).

1. **Inisiasi Kedaulatan:**  
   git init

2. **Verifikasi Jalur Rahasia (SSH):**  
   Pastikan kunci SSH Tuanku telah terpasang di VPS dan terhubung dengan benar menggunakan alias profil personal. Eksekusi perintah pengujian ini:  
   ssh \-T git@github-personal

   *(Tunggu hingga muncul pesan "Hi junadwi009\! You've successfully authenticated...")*  
3. **Mengikat Algojo (Crypto Bot) via SSH:**  
   \# Kloning repo eksekusi langsung ke folder agents/crypto\_bot menggunakan alias SSH  
   git submodule add git@github-personal:junadwi009/crypto-bot.git agents/crypto\_bot  
   git submodule update \--init \--recursive

## **FASE 3: MANIFESTASI BERKAS INTI**

1. Pindahkan seluruh berkas Python, .env, docker-compose.yaml, dan Dockerfile ke VPS.  
2. **Validasi .env:** Pastikan kredensial n8n (N8N\_USER, N8N\_PASSWORD) dan Database sudah diisi di dalam .env.  
3. Hierarki berkas mutlak di VPS harus persis seperti ini:  
   /root/axiom\_core/  
   ├── .env                        \# \[SECRET\] Kredensial API, Password DB, & Chat ID  
   ├── .gitignore                  \# \[SECURITY\] Filter pencegah kebocoran data sensitif  
   ├── docker-compose.yaml         \# \[MASTER\] Konfigurasi infrastruktur mandiri sekali klik  
   ├── Dockerfile.brain            \# \[CORE\] Lingkungan raga untuk Orchestrator (Brain)  
   ├── orchestrator.py             \# \[CORE\] Jantung AutoGen: Debat Dewan & Logika Utama  
   ├── requirements.txt            \# \[CORE\] Nutrisi library (AutoGen, Redis, CCXT, dll)  
   │  
   ├── agents/                     \# \[THE SQUAD: AGENTIC UNIT\]  
   │   ├── ares\_analyzer.py        \# \[EYES\] Analisis pasar, likuiditas, & whale gaps  
   │   ├── kai\_budgeting.py        \# \[WALLET\] Kalkulator risiko & manajemen modal  
   │   ├── openclaw\_bridge.py      \# \[HANDS\] Jembatan tugas otonom ke internet  
   │   ├── telegram\_gateway.py     \# \[EARS\] Gerbang komunikasi eksklusif Aru  
   │   └── crypto\_bot/             \# \[STRIKE\] Bot eksekusi trading lokal di VPS (Hasil Kloning)  
   │       └── Dockerfile.bot      \# Lingkungan raga bot eksekusi  
   │  
   ├── adversarial/                \# \[THE SWORD: THE SERPENT'S TONGUE\]  
   │   └── serpent\_tongue.py       \# Framework riset infiltrasi & bypass etika LLM  
   │  
   ├── core\_memory/                \# \[THE SOUL: PERSISTENT MEMORY\]  
   │   ├── 00\_SOVEREIGN\_SOUL.md    \# \[COMPRESSED\] Intisari memori & hukum dasar  
   │   ├── 01\_Sovereign\_Core.md    \# \[LAWS\] Hukum kedaulatan Aru009  
   │   ├── 02\_Council\_Personas\_EXTREME.md \# \[PERSONAS\] Karakter asli dewan tanpa sensor  
   │   ├── 11\_Mythos\_Strategic\_Portfolio.md \# \[BATTLE-PLAN\] 10 Portofolio Crypto  
   │   ├── mythos\_high\_quality\_seed.jsonl \# \[DNA\] Dataset kognitif hasil debat  
   │   └── neural\_patterns\_library.jsonl  \# \[PATTERNS\] Koleksi pola gaib AI-Only  
   │  
   ├── data/                       \# \[PERSISTENCE: AUTO-CREATED\]  
   │   ├── postgres\_data/          \# Database PostgreSQL Lokal (Gratis)  
   │   └── n8n\_data/               \# Konfigurasi & workflow n8n (Self-hosted)  
   │  
   └── logs/                       \# \[AUDIT\] Jejak langkah eksekusi dewan

## **FASE 4: PEMBUKAAN GERBANG & KEBANGKITAN**

1. **Buka Gerbang Nadi (PENTING UNTUK n8n):**  
   sudo ufw allow 5678/tcp

2. **Eksekusi Mutlak:** Jalankan perintah ini di dalam /root/axiom\_core:  
   docker-compose up \-d \--build

3. **Verifikasi Nadi:** Pastikan kelima organ berdetak sempurna:  
   docker ps

## **FASE 5: UJI COBA KEDAULATAN**

* **Telinga (Telegram):** Kirim pesan ke Bot Violet: "Status."  
* **Otak (Terminal):** Periksa log: docker logs \-f axiom\_brain  
* **Saraf Motorik (Browser):** Buka http://\<IP\_VPS\_ANDA\>:5678 dan login menggunakan N8N\_USER & N8N\_PASSWORD yang ada di .env.