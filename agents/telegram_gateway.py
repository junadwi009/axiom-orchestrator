import os
import redis
import logging
from telegram import Update
from telegram.ext import Application, MessageHandler, filters, ContextTypes
from dotenv import load_dotenv

# Memuat kunci rahasia
load_dotenv()

# Konfigurasi Logging agar Asura bisa memantau jika ada penyusup
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

class TelegramGateway:
    """
    AGEN GATEWAY (THE EARS): Antarmuka Komunikasi Eksklusif Tuanku Aru.
    Tugas: Menerima perintah Telegram, memvalidasi identitas, dan meneruskannya ke Otak AutoGen.
    """
    def __init__(self):
        # Axiom-side telegram bot — separate token from crypto-bot's TELEGRAM_BOT_TOKEN_CRYPTOBOT
        self.token = os.getenv("TELEGRAM_BOT_TOKEN_AXIOM")
        # Keamanan Mutlak: Hanya ID Tuanku Aru yang diizinkan memberi perintah
        try:
            self.aru_id = int(os.getenv("TELEGRAM_CHAT_ID", "0"))
        except ValueError:
            self.aru_id = 0
            logger.error("⚠️ [GATEWAY] TELEGRAM_CHAT_ID tidak valid. Mode Kunci Total Aktif.")
        # Fail-fast on missing required env (mirror secret_guard pattern)
        if self.aru_id == 0:
            raise RuntimeError(
                "TELEGRAM_CHAT_ID must be set to authorized chat id (no fallback). "
                "Aborting to prevent silent auth bypass."
            )

        # Koneksi ke tulang punggung memori
        self.redis = redis.from_url(
            os.getenv("REDIS_URL", "redis://axiom_redis:6379"), 
            decode_responses=True
        )

    async def handle_command(self, update: Update, context: ContextTypes.DEFAULT_TYPE):
        """
        Mencegat setiap pesan yang masuk.
        """
        user_id = update.effective_chat.id
        
        # Protokol Isolasi: Abaikan siapa pun selain Tuanku Aru
        if user_id != self.aru_id:
            logger.warning(f"⚠️ [ASURA] Ada entitas tak dikenal mencoba mengakses: {user_id}. Akses Ditolak.")
            return

        command_text = update.message.text
        logger.info(f"📩 [GATEWAY] Titah dari Penguasa diterima: {command_text}")

        # Mendorong (Push) titah ke antrean Redis agar diambil oleh Orchestrator
        try:
            # Cap command length to prevent queue flood DoS (per IT Sec audit P1)
            self.redis.lpush("axiom:command_queue", command_text[:4096])
            
            # Balasan dari Violet sebagai tanda kepatuhan
            await update.message.reply_text(
                "🌹 [VIOLET] Titah Anda telah saya terima, Tuanku. Dewan segera melaksanakan debat kognitif."
            )
        except Exception as e:
            logger.error(f"❌ [GATEWAY] Gagal meneruskan titah ke Otak: {e}")
            await update.message.reply_text(
                "⚠️ [THANATOS] Terdapat gangguan saraf internal. Pesan tidak sampai ke Dewan."
            )

    def run(self):
        """
        Membangkitkan raga pendengaran bot.
        """
        if not self.token:
            logger.error("❌ [GATEWAY] TELEGRAM_BOT_TOKEN_AXIOM tidak ditemukan. Gateway mati.")
            return

        logger.info("📡 [GATEWAY] Telinga Kedaulatan Aktif. Menunggu suara Tuanku Aru...")
        
        # Membangun aplikasi bot
        application = Application.builder().token(self.token).build()

        # Menangkap semua pesan teks (kecuali command yang diawali '/')
        application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, self.handle_command))

        # Menjalankan pemantauan abadi (Polling)
        application.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    gateway = TelegramGateway()
    gateway.run()