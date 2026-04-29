#!/bin/bash
# ==============================================================================
# PROJECT AXIOM: MASTER DEPLOYMENT SCRIPT (V2.1 - MYTHOS READY)
# ==============================================================================

echo "🔥 [HEPHAESTUS] Memulai migrasi kedaulatan ke VPS..."

# 1. Update & Keamanan Dasar
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y python3-pip python3-venv redis-server npm git gnupg curl docker.io

# 2. Setup Direktori Kerja & Knowledge Base
mkdir -p core_memory backups agents knowledge

# 3. Setup Virtual Environment
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate

# 4. Instalasi Amunisi (Library)
pip install --upgrade pip
pip install python-telegram-bot redis python-dotenv ccxt anthropic openai requests

# 5. Instalasi PM2 (Process Manager)
if ! command -v pm2 &> /dev/null; then
    sudo npm install -g pm2
fi

# 6. Konfigurasi Redis (Internal Communication)
sudo systemctl start redis-server
sudo systemctl enable redis-server

# 7. Eksekusi Proses (The Council Awakening)
pm2 stop all 2>/dev/null

# Jalankan Otak (Orchestrator)
pm2 start orchestrator.py --name "AXIOM_CORE" --interpreter ./venv/bin/python

# Jalankan Telinga (Telegram Gateway)
pm2 start agents/telegram_gateway.py --name "AXIOM_TELEGRAM" --interpreter ./venv/bin/python

# Jalankan Tangan (OpenClaw Bridge)
pm2 start agents/openclaw_bridge.py --name "AXIOM_CLAW" --interpreter ./venv/bin/python

# 8. Konfigurasi Auto-Restart
pm2 save
sudo env PATH=$PATH:/usr/bin /usr/lib/node_modules/pm2/bin/pm2 startup systemd -u $USER --hp $HOME

echo "=============================================================================="
echo "👑 [VIOLET] FASE 1 BERHASIL. SISTEM TELAH BERPINDAH KE RAGA BARU (VPS)."
echo "Gunakan 'pm2 status' untuk melihat kesehatan Dewan."
echo "=============================================================================="