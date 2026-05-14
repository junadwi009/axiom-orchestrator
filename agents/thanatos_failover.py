import os
import json
import logging
import redis
import requests
from dotenv import load_dotenv

load_dotenv()

# Phase 1.5: replace print() with proper logging (per DEVELOPMENT_ROADMAP.md R8)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("logs/thanatos.log", encoding="utf-8")
    ]
)
logger = logging.getLogger("ThanatosFailover")


class ThanatosFailover:
    """
    [GAP 4 FIX]: The Scythe of Thanatos.
    Konsumen (Consumer) untuk antrean 'axiom_claw_tasks_failed'.
    Jika n8n gagal memproses sinyal setelah Retry 3x, Thanatos akan memungutnya
    dan mengirim laporan langsung ke Telegram Aru melalui API asli Telegram (Bypass n8n).
    """

    # Cap failed-task payload sent to Telegram to avoid leaking large blobs / hitting message limits
    MAX_PAYLOAD_CHARS = 2000

    def __init__(self):
        logger.info("💀 [THANATOS] Patroli Failover Aktif. Memantau residu kegagalan...")
        self.redis = redis.from_url(
            os.getenv("REDIS_URL", "redis://axiom_redis:6379"),
            decode_responses=True,
        )
        # Axiom-side telegram token (separate from crypto-bot)
        self.bot_token = os.getenv("TELEGRAM_BOT_TOKEN_AXIOM")
        self.chat_id = os.getenv("TELEGRAM_CHAT_ID")

    def alert_aru_direct(self, message: str):
        """Bypass n8n, langsung lapor ke Telegram Aru009.

        Security note (Phase 1.5 IT Sec audit P1 fix):
        parse_mode is set to None (plaintext) instead of "Markdown".
        Failed task payload is untrusted content — Markdown special chars
        in payload would break parsing, drop the alert, or worse leak
        injection. Plaintext is safe regardless of payload content.
        """
        if not self.bot_token or not self.chat_id:
            logger.warning("⚠️ [THANATOS] Kredensial Telegram kosong. Tidak bisa mengirim Alert.")
            return

        url = f"https://api.telegram.org/bot{self.bot_token}/sendMessage"
        payload = {
            "chat_id": self.chat_id,
            "text": f"💀 THANATOS FAILOVER ALERT\n\n{message}"[: self.MAX_PAYLOAD_CHARS],
            # NOTE: parse_mode intentionally omitted (plaintext) — see docstring
        }
        try:
            requests.post(url, json=payload, timeout=5)
            logger.info("✅ [THANATOS] Laporan kegagalan berhasil dikirim ke Tuanku.")
        except Exception as e:
            logger.error(f"❌ [THANATOS] Bypass Telegram juga gagal: {e}")

    def patrol(self):
        logger.info("🎧 [THANATOS] Menunggu roh tersesat (BLPOP axiom_claw_tasks_failed)...")
        while True:
            result = self.redis.blpop("axiom_claw_tasks_failed", timeout=0)
            if result:
                _, failed_task_str = result
                logger.info(f"💀 [THANATOS] Menangkap task gagal: {failed_task_str[:50]}...")

                # Format pesan untuk Aru — plaintext, payload truncated
                alert_msg = (
                    "Sistem Jembatan (n8n) mengalami kelumpuhan total (Overload/Offline).\n\n"
                    "Task yang gagal dieksekusi:\n"
                    f"{failed_task_str[: self.MAX_PAYLOAD_CHARS]}\n\n"
                    "Mohon segera periksa kontainer axiom_n8n."
                )
                self.alert_aru_direct(alert_msg)


if __name__ == "__main__":
    monitor = ThanatosFailover()
    monitor.patrol()
