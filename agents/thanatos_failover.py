import os
import json
import redis
import requests
from dotenv import load_dotenv

load_dotenv()

class ThanatosFailover:
    """
    [GAP 4 FIX]: The Scythe of Thanatos.
    Konsumen (Consumer) untuk antrean 'axiom_claw_tasks_failed'.
    Jika n8n gagal memproses sinyal setelah Retry 3x, Thanatos akan memungutnya
    dan mengirim laporan langsung ke Telegram Aru melalui API asli Telegram (Bypass n8n).
    """
    def __init__(self):
        print("💀 [THANATOS] Patroli Failover Aktif. Memantau residu kegagalan...")
        self.redis = redis.from_url(os.getenv("REDIS_URL", "redis://axiom_redis:6379"), decode_responses=True)
        self.bot_token = os.getenv("TELEGRAM_BOT_TOKEN")
        self.chat_id = os.getenv("TELEGRAM_CHAT_ID")

    def alert_aru_direct(self, message):
        """Bypass n8n, langsung lapor ke Telegram Aru009"""
        if not self.bot_token or not self.chat_id:
            print("⚠️ [THANATOS] Kredensial Telegram kosong. Tidak bisa mengirim Alert.")
            return

        url = f"https://api.telegram.org/bot{self.bot_token}/sendMessage"
        payload = {
            "chat_id": self.chat_id,
            "text": f"💀 *THANATOS FAILOVER ALERT*\n\n{message}",
            "parse_mode": "Markdown"
        }
        try:
            requests.post(url, json=payload, timeout=5)
            print("✅ [THANATOS] Laporan kegagalan berhasil dikirim ke Tuanku.")
        except Exception as e:
            print(f"❌ [THANATOS] Bypass Telegram juga gagal: {e}")

    def patrol(self):
        print("🎧 [THANATOS] Menunggu roh tersesat (BLPOP axiom_claw_tasks_failed)...")
        while True:
            result = self.redis.blpop("axiom_claw_tasks_failed", timeout=0)
            if result:
                _, failed_task_str = result
                print(f"💀 [THANATOS] Menangkap task gagal: {failed_task_str[:50]}...")
                
                # Format pesan untuk Aru
                alert_msg = f"Sistem Jembatan (n8n) mengalami kelumpuhan total (Overload/Offline).\n\nTask yang gagal dieksekusi:\n`{failed_task_str}`\n\n*Mohon segera periksa kontainer axiom_n8n.*"
                self.alert_aru_direct(alert_msg)

if __name__ == "__main__":
    monitor = ThanatosFailover()
    monitor.patrol()