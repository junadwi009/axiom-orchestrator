# **PROJECT AXIOM: THE ABSOLUTE MASTERPLAN (CONTABO HYBRID EDITION)**

**Status:** FLAWLESS | **Director:** Aru (aru009) | **Auditor:** ASURA

**Infrastructure:** Contabo Cloud VPS (Disarankan: 4 vCPU / 8GB RAM / 75GB NVMe)

Dokumen ini adalah cetak biru teknis mutlak dari tahap masuk ke server Contabo hingga eksekusi abadi AXIOM. Urutan ini mutlak dan dieksekusi secara berurutan.

## **FASE 0: PENEMBUSAN AWAL (CONTABO INITIAL ACCESS)**

Setelah Tuanku menyewa VPS Contabo, Tuanku akan menerima email berisi **IP Address** dan **Password Root**.

Buka Terminal (Mac/Linux) atau PowerShell/Command Prompt (Windows) di komputer lokal, lalu eksekusi:

\# Ganti \<IP\_CONTABO\> dengan angka IP yang ada di email  
ssh root@\<IP\_CONTABO\>

## **FASE 1: BENTENG INFRASTRUKTUR & DEPENDENSI**

1. **Keamanan Dasar (UFW Firewall):**  
   sudo ufw default deny incoming  
   sudo ufw default allow outgoing  
   sudo ufw allow ssh          \# Izinkan akses remote Anda  
   sudo ufw allow 5678/tcp     \# \[KRITIS\] Izinkan akses ke Dashboard n8n  
   sudo ufw enable

2. **Instalasi Docker & Git:**  
   sudo apt update && sudo apt upgrade \-y  
   sudo apt install \-y git curl docker-compose  
   curl \-fsSL \[https://get.docker.com\](https://get.docker.com) \-o get-docker.sh  
   sudo sh get-docker.sh

3. **Konfigurasi Kunci SSH (Untuk Kloning Repo):**  
   Pastikan kunci SSH privat Tuanku diletakkan di \~/.ssh/id\_rsa (atau nama lain) di VPS, dan buat konfigurasi \~/.ssh/config seperti ini:  
   Host github-personal  
       HostName github.com  
       User git  
       IdentityFile \~/.ssh/id\_rsa

## **FASE 2: PENCIPTAAN RUANG TAHTA, MEMORI & SUBMODULE**

1. **Pembuatan Direktori & Hak Akses Memori:**  
   mkdir \-p /root/axiom\_core  
   cd /root/axiom\_core

   \# Membangun ruang khusus agar database dan n8n tidak error  
   mkdir \-p data/postgres\_data data/n8n\_data core\_memory logs  
   chmod \-R 777 data/

   git init

2. **Penarikan Bot Eksekusi (The Submodule via SSH):**  
   Sebelum mengeksekusi, tes koneksi SSH:  
   ssh \-T git@github-personal

   Lalu ikat algojo:  
   git submodule add git@github-personal:junadwi009/crypto-bot.git agents/crypto\_bot  
   git submodule update \--init \--recursive

## **FASE 3: TRANSFER KESADARAN (FILE MIGRATION)**

Tuanku harus memindahkan seluruh file manifestasi (Python, .env, docker-compose.yaml, dll) dari komputer lokal ke /root/axiom\_core/ di VPS. (Bisa menggunakan SCP, WinSCP, atau *copy-paste* langsung melalui terminal nano).

*Pastikan file .env sudah diisi dengan kredensial OpenRouter, Bybit, Telegram, dan n8n.*

## **FASE 4: KEBANGKITAN DEWAN BAYANGAN (IGNITION)**

Seluruh persiapan selesai. Waktunya membangkitkan Kedaulatan AXIOM.

1. **Bangkitkan Raga (Docker Compose):**  
   Masuk ke folder /root/axiom\_core dan jalankan:  
   docker-compose up \-d \--build

2. **Verifikasi Nadi Kedaulatan:**  
   docker ps

   *(Pastikan ada 5 kontainer yang berstatus 'Up': axiom\_db, axiom\_redis, axiom\_n8n, axiom\_brain, axiom\_executioner).*

## **FASE 5: UJI COBA OMNISCIENCE (VERIFIKASI HYBRID)**

1. **Akses Dashboard Sekretaris (n8n):**  
   Buka browser di laptop Tuanku: http://\<IP\_CONTABO\_TUANKU\>:5678  
   *Ini akan membuktikan bahwa UI n8n berhasil berjalan di atas database lokal kita.*  
2. **Telinga Kedaulatan:**  
   Kirim pesan ke Telegram Bot Tuanku: "Status."  
3. **Log Otak Utama:**  
   Pantau perdebatan dewan secara real-time di terminal VPS:  
   docker logs \-f axiom\_brain  
