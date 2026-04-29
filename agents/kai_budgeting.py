import os
import math
import logging
from datetime import datetime
from dotenv import load_dotenv

load_dotenv()
logger = logging.getLogger(__name__)


class KaiBudgeting:
    """
    AGEN KAI (THE WALLET): CFO & Manajer Risiko Kedaulatan.
    [FIXED V4]:
    - ADDED: record_trade_result() sebagai feedback loop PnL nyata ke Orchestrator
    - ADDED: get_session_summary() untuk laporan sesi trading
    - FIXED: Logging standar menggantikan print() raw
    - IMPROVED: Proyeksi yang lebih realistis dengan disclaimer
    """

    def __init__(self):
        logger.info("⚖️ [KAI] Buku besar V4 Aktif.")

        self.initial_capital = float(os.getenv("INITIAL_CAPITAL", 213.0))
        self.daily_rate = float(os.getenv('DAILY_TARGET_PCT', 3.0)) / 100.0  # env-driven; default 3.0% per Konflik 10
        self.bybit_taker_fee = 0.00055  # Taker fee Bybit 0.055%
        self.drawdown_limit = 0.15      # 15% Drawdown Guillotine

        self.peak_balance = self.initial_capital
        self.consecutive_losses = 0

        # [NEW] Session tracking untuk feedback loop
        self.session_trades = []
        self.session_start = datetime.now()

    # ------------------------------------------------------------------
    # CORE RISK MANAGEMENT
    # ------------------------------------------------------------------

    def calculate_position_size(self, current_balance: float) -> float:
        """
        Menghitung margin bersih yang aman setelah fee dan circuit breaker.
        Return 0.0 jika drawdown kritis atau modal tidak cukup.
        """
        # Update peak
        if current_balance > self.peak_balance:
            self.peak_balance = current_balance

        # Drawdown Guillotine
        drawdown = (self.peak_balance - current_balance) / self.peak_balance
        if drawdown >= self.drawdown_limit:
            logger.critical(
                f"💀 [KAI] DRAWDOWN {drawdown * 100:.2f}%! "
                f"Melebihi limit {self.drawdown_limit * 100}%. MODAL DIKUNCI."
            )
            return 0.0

        # Circuit Breaker: 3 loss berturut-turut → kurangi risk drastis
        if self.consecutive_losses >= 3:
            risk_pct = 0.005  # 0.5%
            logger.warning(f"⚡ [KAI] Circuit Breaker aktif ({self.consecutive_losses} losses). Risk diturunkan ke 0.5%.")
        elif self.consecutive_losses >= 1:
            risk_pct = 0.01   # 1% setelah 1-2 loss
        else:
            risk_pct = 0.02   # 2% normal

        raw_margin = current_balance * risk_pct
        # Fee masuk + keluar (taker x2)
        total_fees = raw_margin * (self.bybit_taker_fee * 2)
        net_margin = raw_margin - total_fees

        logger.info(
            f"⚖️ [KAI] Saldo: ${current_balance:.2f} | "
            f"Risk: {risk_pct*100:.1f}% | Margin Bersih: ${net_margin:.4f} | "
            f"Fee: ${total_fees:.4f}"
        )
        # Minimum order Bybit $5
        return max(round(net_margin, 4), 5.0)

    # ------------------------------------------------------------------
    # FEEDBACK LOOP (baru — menghubungkan hasil bot.py ke Orchestrator)
    # ------------------------------------------------------------------

    def record_trade_result(self, symbol: str, action: str,
                            pnl_usd: float, new_balance: float):
        """
        [NEW] Mencatat hasil trade nyata dari Executioner.
        Dipanggil setelah setiap order tereksekusi untuk memperbarui
        consecutive_losses dan peak_balance secara akurat.
        """
        self.session_trades.append({
            "time": datetime.now().strftime("%H:%M:%S"),
            "symbol": symbol,
            "action": action,
            "pnl_usd": pnl_usd,
            "balance": new_balance
        })

        if pnl_usd < 0:
            self.consecutive_losses += 1
            logger.warning(
                f"📉 [KAI] Loss #{self.consecutive_losses}: {symbol} "
                f"PnL=${pnl_usd:.2f} | Saldo: ${new_balance:.2f}"
            )
        else:
            self.consecutive_losses = 0
            logger.info(
                f"📈 [KAI] Profit: {symbol} PnL=+${pnl_usd:.2f} | "
                f"Saldo: ${new_balance:.2f}"
            )

        # Selalu update peak setelah trade
        if new_balance > self.peak_balance:
            self.peak_balance = new_balance

    def get_session_summary(self) -> dict:
        """Ringkasan sesi untuk Asura dan laporan Telegram."""
        if not self.session_trades:
            return {"message": "Belum ada trade dalam sesi ini."}

        total_pnl = sum(t["pnl_usd"] for t in self.session_trades)
        wins = sum(1 for t in self.session_trades if t["pnl_usd"] > 0)
        losses = len(self.session_trades) - wins
        win_rate = round(wins / len(self.session_trades) * 100, 1) if self.session_trades else 0
        duration = str(datetime.now() - self.session_start).split(".")[0]

        return {
            "total_trades": len(self.session_trades),
            "wins": wins,
            "losses": losses,
            "win_rate_pct": win_rate,
            "total_pnl_usd": round(total_pnl, 4),
            "consecutive_losses": self.consecutive_losses,
            "peak_balance": round(self.peak_balance, 2),
            "session_duration": duration,
        }

    # ------------------------------------------------------------------
    # PROYEKSI (untuk referensi, bukan target mutlak)
    # ------------------------------------------------------------------

    def get_compounding_path(self, days: int = 30, daily_rate: float = None) -> list:
        """
        Proyeksi saldo dengan compounding rate tertentu.
        Default menggunakan self.daily_rate (env-driven via DAILY_TARGET_PCT, default 3.0%). Gunakan angka realistis.
        """
        rate = daily_rate if daily_rate is not None else self.daily_rate
        return [
            {
                "day": i + 1,
                "balance": round(self.initial_capital * math.pow(1 + rate, i + 1), 2)
            }
            for i in range(days)
        ]


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    kai = KaiBudgeting()

    # Test skenario
    print("\n=== PROYEKSI 7 HARI (2% daily) ===")
    for p in kai.get_compounding_path(7):
        print(f"  Hari {p['day']:>2}: ${p['balance']}")

    print("\n=== SIMULASI POSISI ===")
    margin = kai.calculate_position_size(213.0)
    print(f"  Margin diizinkan: ${margin}")

    print("\n=== SIMULASI 2 LOSS BERTURUT ===")
    kai.record_trade_result("BTC/USDT", "BUY", -4.5, 208.5)
    kai.record_trade_result("ETH/USDT", "BUY", -2.1, 206.4)
    margin_after = kai.calculate_position_size(206.4)
    print(f"  Margin setelah 2 loss: ${margin_after}")

    print("\n=== SESSION SUMMARY ===")
    print(kai.get_session_summary())
