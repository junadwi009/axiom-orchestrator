> **⚠️ ARCHITECTURE UPDATE — 2026-04-27**
>
> Dokumen ini punya **lore value** dan deskripsi historis identitas axiom. Beberapa section di bawah merefleksikan **arsitektur lama** (executor pattern, OpenClaw Bridge sebagai Bybit V5 executor, target 9.1% harian) yang sudah **superseded** oleh arsitektur baru paska-Konflik 1-10:
>
> - axiom = **observer/teacher only**, bukan executor (R6, [ARCHITECTURE.md](../ARCHITECTURE.md) §4.2)
> - crypto-bot = autonomous trading product (R6)
> - daily target = **3.0%** (Konflik 10), sebelumnya 9.1%
> - drawdown guillotine = **15%** (DRAWDOWN_LIMIT_PCT)
> - paper trade default = true (R10)
>
> Persona dan filosofi di file ini tetap **valid sebagai karakter dewan AutoGen** untuk warna debate Council. Operational behavior tetap dibatasi oleh [CLAUDE_INSTRUCTIONS.md](../CLAUDE_INSTRUCTIONS.md) hard rules R1-R10.
>
> Untuk ground truth operational architecture, baca: [ARCHITECTURE.md](../ARCHITECTURE.md), [INTEGRATION_GUIDE.md](../INTEGRATION_GUIDE.md), [AI_CAPABILITIES.md](../AI_CAPABILITIES.md).

---

# **🧩 SOVEREIGN SOUL: COMPRESSED MEMORY (V3.0 \- OMNISCIENCE)**

**Project:** AXIOM MYTHOS | **Owner:** Aru (aru009)

## **👑 PROTOKOL INTI**

* **Kedaulatan:** Mandiri sepenuhnya (Independent VPS Docker).  
* **Target:** $200 \-\> $10,000 (Pure Crypto) dalam 30-45 Hari.  
* **Logika Kognitif:** Dual-Model Logic (Hermes-4 untuk Presisi Kalkulasi, Hermes-3 untuk Karakter Uncensored) & Intelligence Routing (Efisiensi Token).  
* **Dewan:** 8 Entitas AutoGen (Violet, Asura, Ares, Kai, Thanatos, Atlas, Eve, Nero).

## **🛡️ ARSITEKTUR HYBRID**

* **Brain:** AutoGen Multi-Agent (Python).  
* **Nervous:** n8n (Self-hosted, Rp0 OpEx).  
* **Memory:** PostgreSQL & Redis (Local).  
* **Strike:** OpenClaw Bridge (Zero-Latency Redis BLPOP) mengeksekusi langsung ke Bybit V5 dalam \<1ms.