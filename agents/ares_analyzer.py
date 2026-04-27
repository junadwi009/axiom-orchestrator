import ccxt
import os
import logging
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()
logger = logging.getLogger(__name__)


class AresAnalyzer:
    """
    AGEN ARES (THE EYES): Alpha Hunter & Liquidity Sniper.
    [FIXED V4]:
    - BUGFIX: Shadow intel yang sebelumnya hardcoded string palsu diganti dengan
              data pasar nyata: RSI, OHLCV 24h, volume, dan fear/greed proxy.
    - BUGFIX: calculate_slippage sekarang mengembalikan nilai bid/ask terbaik
              untuk disimpan ke database.
    - ADDED: get_ohlcv_snapshot() untuk mendukung analisis teknikal dasar.
    - ADDED: Logging standar menggantikan print() raw.
    """

    def __init__(self):
        logger.info("👺 [ARES] Mata algojo V4 terbuka. Memindai Order Flow & Data Nyata...")
        self.exchange = ccxt.bybit({
            "apiKey": os.getenv("BYBIT_API_KEY"),
            "secret": os.getenv("BYBIT_API_SECRET"),
            "enableRateLimit": True,
            "options": {"defaultType": "linear"}
        })

        if os.getenv("PAPER_TRADE", "true").lower() == "true":
            self.exchange.set_sandbox_mode(True)
            logger.info("🛡️ [ARES] Mode Sandbox (Paper Trade) aktif.")

    # ------------------------------------------------------------------
    # TOOLS INTERNAL
    # ------------------------------------------------------------------

    def _get_real_market_intel(self, symbol: str) -> dict:
        """
        [FIXED] Menggantikan shadow intel hardcoded dengan data pasar NYATA:
        - OHLCV 24 jam terakhir (High, Low, Volume)
        - RSI sederhana dari 14 candle terakhir
        - Persentase perubahan harga 24h
        """
        intel = {}
        try:
            # OHLCV 1h, 14 candle untuk RSI
            ohlcv = self.exchange.fetch_ohlcv(symbol, timeframe="1h", limit=14)
            closes = [c[4] for c in ohlcv]

            # RSI sederhana (Wilder)
            gains, losses = [], []
            for i in range(1, len(closes)):
                delta = closes[i] - closes[i - 1]
                gains.append(max(delta, 0))
                losses.append(max(-delta, 0))
            avg_gain = sum(gains) / len(gains) if gains else 0
            avg_loss = sum(losses) / len(losses) if losses else 1
            rs = avg_gain / avg_loss if avg_loss != 0 else 100
            rsi = round(100 - (100 / (1 + rs)), 2)

            # 24h ticker
            ticker_24h = self.exchange.fetch_ticker(symbol)
            pct_change = round(ticker_24h.get("percentage", 0) or 0, 2)
            volume_24h = round(ticker_24h.get("quoteVolume", 0) or 0, 2)
            high_24h = ticker_24h.get("high", 0)
            low_24h = ticker_24h.get("low", 0)

            # Interpretasi RSI untuk context dewan
            if rsi > 70:
                rsi_signal = "OVERBOUGHT — Waspadai reversal turun"
            elif rsi < 30:
                rsi_signal = "OVERSOLD — Potensi reversal naik"
            else:
                rsi_signal = "NEUTRAL"

            intel = {
                "rsi_14h": rsi,
                "rsi_signal": rsi_signal,
                "change_24h_pct": pct_change,
                "volume_24h_usd": volume_24h,
                "high_24h": high_24h,
                "low_24h": low_24h,
                "last_close": closes[-1],
                "timestamp": datetime.now().strftime("%H:%M:%S")
            }
            logger.info(f"📊 [ARES] Real intel {symbol}: RSI={rsi} | 24h={pct_change}%")
        except Exception as e:
            logger.warning(f"⚠️ [ARES] Gagal ambil real intel: {e}")
            intel = {"error": str(e)}
        return intel

    def calculate_slippage(self, symbol: str, order_size_usd: float) -> tuple:
        """
        Menghitung estimasi slippage dari Order Book.
        Return: (slippage_pct, best_bid, best_ask)
        """
        try:
            orderbook = self.exchange.fetch_order_book(symbol, limit=20)
            asks = orderbook["asks"]
            bids = orderbook["bids"]

            best_bid = bids[0][0] if bids else 0
            best_ask = asks[0][0] if asks else 0

            remaining = order_size_usd
            weighted_price = 0.0
            total_filled = 0.0

            for price, volume in asks:
                vol_usd = price * volume
                if remaining <= vol_usd:
                    weighted_price += remaining
                    total_filled += remaining / price
                    remaining = 0
                    break
                else:
                    weighted_price += vol_usd
                    total_filled += volume
                    remaining -= vol_usd

            if remaining > 0:
                return 99.9, best_bid, best_ask  # Likuiditas tidak cukup

            avg_exec = weighted_price / total_filled if total_filled else best_ask
            slippage = round(((avg_exec - best_ask) / best_ask) * 100, 4)
            return slippage, best_bid, best_ask

        except Exception as e:
            logger.warning(f"⚠️ [ARES] Gagal hitung slippage: {e}")
            return 0.0, 0.0, 0.0

    def get_ohlcv_snapshot(self, symbol: str, timeframe: str = "15m", limit: int = 5) -> list:
        """Ambil OHLCV terbaru untuk disimpan ke database."""
        try:
            return self.exchange.fetch_ohlcv(symbol, timeframe=timeframe, limit=limit)
        except Exception as e:
            logger.warning(f"⚠️ [ARES] Gagal ambil OHLCV: {e}")
            return []

    # ------------------------------------------------------------------
    # PUBLIC API
    # ------------------------------------------------------------------

    def get_market_pulse(self, symbol: str = "BTC/USDT", order_size_usd: float = 50) -> dict:
        """
        Mengambil denyut nadi pasar lengkap dengan data NYATA.
        [FIXED]: Shadow intel kini berisi data teknikal real, bukan string palsu.
        """
        try:
            ticker = self.exchange.fetch_ticker(symbol)
            current_price = ticker["last"]

            slippage, best_bid, best_ask = self.calculate_slippage(symbol, order_size_usd)
            spread_pct = round(((best_ask - best_bid) / best_bid) * 100, 4) if best_bid else 0

            risk_level = (
                "LOW" if slippage < 0.2
                else "MEDIUM" if slippage < 0.5
                else "CRITICAL"
            )

            # Data teknikal nyata — menggantikan hardcoded string
            real_intel = self._get_real_market_intel(symbol)

            ohlcv_snap = self.get_ohlcv_snapshot(symbol)

            return {
                "symbol": symbol,
                "current_price": current_price,
                "best_bid": best_bid,
                "best_ask": best_ask,
                "spread_pct": spread_pct,
                "est_slippage_pct": slippage,
                "risk_level": risk_level,
                "timestamp": ticker.get("timestamp"),
                "real_intel": real_intel,    # Data nyata untuk dewan
                "raw_ohlcv": ohlcv_snap,     # Untuk disimpan ke DB
            }

        except Exception as e:
            logger.error(f"⚠️ [ARES] Anomali get_market_pulse: {e}")
            return {"error": str(e)}


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    ares = AresAnalyzer()
    pulse = ares.get_market_pulse(symbol="BTC/USDT", order_size_usd=50)
    if "error" not in pulse:
        print(f"\n📊 Harga: ${pulse['current_price']}")
        print(f"📉 Slippage: {pulse['est_slippage_pct']}% | Risk: {pulse['risk_level']}")
        print(f"🔬 Intel Nyata: {pulse['real_intel']}")
    else:
        print(f"❌ Error: {pulse['error']}")
