import os
import json
import redis
import logging
import requests
from datetime import datetime
from urllib3.util.retry import Retry
from requests.adapters import HTTPAdapter
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("logs/bridge.log", encoding="utf-8")
    ]
)
logger = logging.getLogger("OpenClawBridge")


class OpenClawBridge:
    """
    [HANDS] Saraf Motorik — Jembatan Redis → n8n Webhook (BUKAN Bybit executor).

    Naming clarification (Phase 1.5 per DEVELOPMENT_ROADMAP.md):
    The "OpenClaw" name is historical (pre-Konflik 2 nomenclature). This class is
    functionally an *n8n webhook bridge* — it consumes 'axiom_claw_tasks' from Redis
    and POSTs each task to the configured n8n webhook URL. It does NOT place orders
    on any exchange. Exchange order placement happens in crypto-bot (cryptobot_main
    container) via pybit.

    File rename to `n8n_bridge.py` deferred until Phase 3+ (when this service is
    actually activated via the phase3plus profile + Dockerfile.bridge).

    [FIXED V3]:
    - Logging standar ke file logs/bridge.log
    - Retry strategy tetap dipertahankan (sudah solid)
    - Payload diperkaya dengan metadata untuk debugging n8n
    """

    def __init__(self):
        logger.info("🛠️ [BRIDGE] Saraf motorik V3 aktif.")

        self.redis = redis.from_url(
            os.getenv("REDIS_URL", "redis://axiom_redis:6379"),
            decode_responses=True
        )
        self.webhook_url = os.getenv("WEBHOOK_URL", "http://axiom_n8n:5678/webhook/claw")
        self.auth_user = os.getenv("N8N_USER", "")
        self.auth_pass = os.getenv("N8N_PASSWORD", "")

        # Retry: 3x dengan backoff 1s, 2s, 4s
        self.session = requests.Session()
        retry = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504]
        )
        self.session.mount("http://", HTTPAdapter(max_retries=retry))
        self.session.mount("https://", HTTPAdapter(max_retries=retry))

    def send_task(self, task_data: dict):
        """Kirim task ke n8n webhook dengan metadata."""
        payload = {
            "task": task_data,
            "timestamp": datetime.now().isoformat(),
            "source": "axiom_core_brain"
        }
        try:
            auth = (self.auth_user, self.auth_pass) if self.auth_user else None
            response = self.session.post(
                self.webhook_url, json=payload, auth=auth, timeout=5
            )
            if response.status_code == 200:
                logger.info("✅ [BRIDGE] Sinyal menembus n8n.")
            else:
                logger.warning(f"⚠️ [BRIDGE] n8n menolak. Status: {response.status_code}")
        except Exception as e:
            logger.error(f"❌ [BRIDGE] Koneksi putus setelah retry: {e}")
            # Simpan ke dead-letter queue → Thanatos akan ambil ini
            self.redis.lpush("axiom_claw_tasks_failed", json.dumps(payload))

    def listen_to_brain(self):
        """Loop utama: BLPOP axiom_claw_tasks, zero-latency."""
        logger.info("🎧 [BRIDGE] Menunggu instruksi (BLPOP axiom_claw_tasks)...")
        while True:
            result = self.redis.blpop("axiom_claw_tasks", timeout=0)
            if result:
                _, task_string = result
                try:
                    task_data = json.loads(task_string)
                except json.JSONDecodeError:
                    task_data = {"raw": task_string}

                logger.info(f"🚀 [BRIDGE] Menangkap sinyal: {str(task_data)[:80]}...")
                self.send_task(task_data)


if __name__ == "__main__":
    bridge = OpenClawBridge()
    bridge.listen_to_brain()
