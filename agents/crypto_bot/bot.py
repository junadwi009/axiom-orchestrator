import os
import json
import redis
import ccxt
import logging
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("logs/executioner.log", encoding="utf-8")
    ]
)
logger = logging.getLogger("Executioner")


class OpenClawExecutioner:
    """
    [STRIKE] Raga Sang Algojo — Bot Eksekusi Order ke Bybit.
    [FIXED V4]:
    - BUGFIX: Membaca field 'size_usd' (sesuai yang dikirim Orchestrator V4),
              bukan 'amount' yang menyebabkan order selalu di-skip.
    - ADDED: Setelah order selesai, push PnL result ke Redis queue 'axiom_pnl_results'
             sehingga Kai bisa update feedback loop secara otomatis.
    - ADDED: Logging ke file logs/executioner.log
    - IMPROVED: Kalkulasi amount coin lebih aman dengan rounding sesuai market precision.
    """

    def __init__(self):
        logger.info("🗡️ [EXECUTIONER] Algojo terbangun. Memuat senjata Bybit V5...")

        self.redis = redis.from_url(
            os.getenv("REDIS_URL", "redis://axiom_redis:6379"),
            decode_responses=True
        )

        self.exchange = ccxt.bybit({
            "apiKey": os.getenv("BYBIT_API_KEY"),
            "secret": os.getenv("BYBIT_API_SECRET"),
            "enableRateLimit": True,
            "options": {"defaultType": "linear"}
        })

        self.is_paper = os.getenv("PAPER_TRADE", "true").lower() == "true"
        if self.is_paper:
            self.exchange.set_sandbox_mode(True)
            logger.info("🛡️ [EXECUTIONER] Mode PAPER TRADE (Sandbox) aktif.")

        # Cache balance awal untuk hitung PnL sederhana
        self._last_balance = float(os.getenv("INITIAL_CAPITAL", 213.0))

    # ------------------------------------------------------------------
    # HELPERS
    # ------------------------------------------------------------------

    def _get_current_balance(self) -> float:
        """Ambil saldo USDT terkini dari Bybit."""
        try:
            balance = self.exchange.fetch_balance()
            return float(balance.get("USDT", {}).get("free", self._last_balance))
        except Exception as e:
            logger.warning(f"⚠️ [EXECUTIONER] Gagal ambil saldo: {e}")
            return self._last_balance

    def _calc_amount(self, symbol: str, size_usd: float):
        """
        Menghitung jumlah koin dari nilai USD.
        Return (amount, entry_price) atau (None, None) jika error.
        """
        try:
            ticker = self.exchange.fetch_ticker(symbol)
            price = ticker["last"]
            raw_amount = size_usd / price

            # Bulatkan sesuai market precision Bybit
            market = self.exchange.market(symbol)
            precision = market.get("precision", {}).get("amount", 8)
            amount = float(self.exchange.amount_to_precision(symbol, raw_amount))

            return amount, price
        except Exception as e:
            logger.error(f"❌ [EXECUTIONER] Gagal kalkulasi amount {symbol}: {e}")
            return None, None

    def _push_pnl_feedback(self, symbol: str, action: str,
                           size_usd: float, entry_price: float,
                           order_id: str):
        """
        [NEW] Push estimasi PnL ke Redis setelah order masuk.
        Orchestrator → Kai akan membaca queue ini untuk update feedback loop.
        Catatan: PnL nyata dihitung setelah posisi ditutup; ini adalah placeholder
        yang bisa disempurnakan ketika close-order juga dimonitor.
        """
        balance_now = self._get_current_balance()
        pnl_estimate = balance_now - self._last_balance
        self._last_balance = balance_now

        payload = {
            "symbol": symbol,
            "action": action,
            "size_usd": size_usd,
            "entry_price": entry_price,
            "order_id": order_id,
            "pnl_usd": round(pnl_estimate, 4),
            "new_balance": round(balance_now, 4),
            "timestamp": datetime.now().isoformat()
        }
        self.redis.lpush("axiom_pnl_results", json.dumps(payload))
        logger.info(f"📤 [EXECUTIONER] PnL feedback dikirim ke Kai: {payload}")

    # ------------------------------------------------------------------
    # CORE
    # ------------------------------------------------------------------

    def execute_trade(self, signal: dict):
        """
        Mengeksekusi sinyal trading dari Orchestrator.
        [FIXED]: Membaca 'size_usd' (bukan 'amount').
        """
        action = signal.get("action", "").upper()
        symbol = signal.get("symbol", "")
        # [FIXED] Field yang benar adalah size_usd
        size_usd = float(signal.get("size_usd", 0))

        if action not in ("BUY", "SELL"):
            logger.warning(f"⚠️ [EXECUTIONER] Action tidak valid, diabaikan: {signal}")
            return

        if size_usd <= 0:
            logger.warning("⚠️ [EXECUTIONER] size_usd=0 atau tidak ada, sinyal diabaikan.")
            return

        logger.info(f"⚔️ [ARES STRIKE] Mengeksekusi {action} {symbol} senilai ${size_usd}...")

        amount, entry_price = self._calc_amount(symbol, size_usd)
        if not amount:
            return

        try:
            side = "buy" if action == "BUY" else "sell"
            order = self.exchange.create_market_order(symbol, side, amount)
            order_id = order.get("id", "N/A")

            logger.info(
                f"✅ [EXECUTIONER] ORDER BERHASIL! "
                f"ID={order_id} | {action} {symbol} | "
                f"Amount={amount} | Entry≈${entry_price}"
            )

            # Notifikasi sukses ke Telegram via Redis
            notif = (
                f"⚔️ EKSEKUSI MUTLAK!\n"
                f"Action : {action}\n"
                f"Symbol : {symbol}\n"
                f"Size   : ${size_usd}\n"
                f"Amount : {amount}\n"
                f"Entry  : ${entry_price}\n"
                f"OrderID: {order_id}"
            )
            self.redis.lpush("telegram_to_orchestrator", f"NOTIFY_ARU: {notif}")

            # [NEW] Push PnL feedback ke Kai
            self._push_pnl_feedback(symbol, action, size_usd, entry_price, order_id)

        except Exception as e:
            err_msg = f"💀 GAGAL EKSEKUSI {symbol}: {e}"
            logger.error(f"[EXECUTIONER FATAL] {err_msg}")
            self.redis.lpush("telegram_to_orchestrator", f"NOTIFY_ARU: ⚠️ {err_msg}")

    def listen_for_blood(self):
        """Loop utama: mendengarkan sinyal dari Orchestrator via Redis BLPOP."""
        logger.info("🎧 [EXECUTIONER] Menunggu perintah eksekusi (BLPOP bybit_execution_queue)...")
        while True:
            result = self.redis.blpop("bybit_execution_queue", timeout=0)
            if result:
                _, signal_string = result
                try:
                    signal = json.loads(signal_string)
                    self.execute_trade(signal)
                except json.JSONDecodeError as e:
                    logger.error(f"❌ [EXECUTIONER] Gagal parse JSON sinyal: {e} | Raw: {signal_string[:100]}")


if __name__ == "__main__":
    bot = OpenClawExecutioner()
    bot.listen_for_blood()
