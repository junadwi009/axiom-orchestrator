"""
PROJECT AXIOM: BACKTESTING FRAMEWORK (V1)
==========================================
Menguji strategi scalping AXIOM menggunakan data historis OHLCV dari Bybit
TANPA menyentuh modal nyata. Wajib dijalankan sebelum live trading.

Cara pakai:
    python backtest.py --symbol BTC/USDT --days 30 --timeframe 15m
"""

import argparse
import os
import math
import json
import logging
from datetime import datetime, timedelta
from dataclasses import dataclass, field
from typing import List, Tuple

import ccxt
import pandas as pd

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("Backtest")


# ==============================================================================
# DATA STRUCTURES
# ==============================================================================

@dataclass
class Trade:
    entry_time: str
    exit_time: str
    symbol: str
    action: str          # BUY / SELL
    entry_price: float
    exit_price: float
    size_usd: float
    pnl_usd: float
    pnl_pct: float
    fee_usd: float
    is_win: bool


@dataclass
class BacktestResult:
    symbol: str
    timeframe: str
    period_days: int
    initial_capital: float
    final_capital: float
    total_return_pct: float
    total_trades: int
    winning_trades: int
    losing_trades: int
    win_rate_pct: float
    max_drawdown_pct: float
    avg_pnl_per_trade: float
    total_fees_paid: float
    sharpe_ratio: float
    trades: List[Trade] = field(default_factory=list)


# ==============================================================================
# INDICATORS
# ==============================================================================

def calc_rsi(closes: pd.Series, period: int = 14) -> pd.Series:
    """RSI Wilder — sama dengan yang dipakai AresAnalyzer."""
    delta = closes.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = gain.ewm(com=period - 1, min_periods=period).mean()
    avg_loss = loss.ewm(com=period - 1, min_periods=period).mean()
    rs = avg_gain / avg_loss.replace(0, 1e-10)
    return 100 - (100 / (1 + rs))


def calc_ema(closes: pd.Series, period: int) -> pd.Series:
    return closes.ewm(span=period, adjust=False).mean()


def calc_atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    high_low = df["high"] - df["low"]
    high_close = (df["high"] - df["close"].shift()).abs()
    low_close = (df["low"] - df["close"].shift()).abs()
    tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
    return tr.ewm(com=period - 1, min_periods=period).mean()


def generate_signals(df: pd.DataFrame) -> pd.DataFrame:
    """
    Strategi AXIOM: RSI + EMA Cross + ATR filter.
    Signal BUY  : RSI < 40 & EMA9 crosses above EMA21 & spread layak
    Signal SELL : RSI > 60 & EMA9 crosses below EMA21
    Signal EXIT : RSI mencapai zona opposite atau SL 1.5x ATR
    """
    df = df.copy()
    df["rsi"] = calc_rsi(df["close"], 14)
    df["ema9"] = calc_ema(df["close"], 9)
    df["ema21"] = calc_ema(df["close"], 21)
    df["atr"] = calc_atr(df, 14)

    df["ema_cross_up"] = (df["ema9"] > df["ema21"]) & (df["ema9"].shift() <= df["ema21"].shift())
    df["ema_cross_down"] = (df["ema9"] < df["ema21"]) & (df["ema9"].shift() >= df["ema21"].shift())

    df["signal"] = "HOLD"
    df.loc[(df["rsi"] < 40) & df["ema_cross_up"], "signal"] = "BUY"
    df.loc[(df["rsi"] > 60) & df["ema_cross_down"], "signal"] = "SELL"

    return df


# ==============================================================================
# CORE BACKTEST ENGINE
# ==============================================================================

class BacktestEngine:

    BYBIT_FEE = 0.00055   # Taker 0.055%
    SL_ATR_MULT = 1.5     # Stop Loss = 1.5x ATR
    TP_ATR_MULT = 2.5     # Take Profit = 2.5x ATR (Risk:Reward 1:1.67)

    def __init__(self, initial_capital: float = 213.0):
        self.initial_capital = initial_capital
        self.bybit_fee = self.BYBIT_FEE

    def fetch_ohlcv(self, symbol: str, timeframe: str, days: int) -> pd.DataFrame:
        """Ambil data historis dari Bybit via CCXT."""
        logger.info(f"📡 Mengunduh OHLCV {symbol} [{timeframe}] {days} hari...")
        try:
            exchange = ccxt.bybit({"enableRateLimit": True, "options": {"defaultType": "linear"}})
            since = exchange.parse8601(
                (datetime.utcnow() - timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
            )
            all_ohlcv = []
            limit = 200
            while True:
                batch = exchange.fetch_ohlcv(symbol, timeframe, since=since, limit=limit)
                if not batch:
                    break
                all_ohlcv.extend(batch)
                since = batch[-1][0] + 1
                if len(batch) < limit:
                    break

            df = pd.DataFrame(all_ohlcv, columns=["timestamp", "open", "high", "low", "close", "volume"])
            df["datetime"] = pd.to_datetime(df["timestamp"], unit="ms")
            df = df.drop_duplicates("timestamp").sort_values("timestamp").reset_index(drop=True)
            logger.info(f"✅ {len(df)} candle berhasil diunduh.")
            return df
        except Exception as e:
            logger.error(f"❌ Gagal fetch OHLCV: {e}")
            raise

    def _calc_position_size(self, balance: float, peak: float, consec_losses: int) -> float:
        """Mirror logika KaiBudgeting — konsisten dengan live system."""
        drawdown = (peak - balance) / peak if peak > 0 else 0
        if drawdown >= 0.15:
            return 0.0
        risk_pct = 0.02 if consec_losses == 0 else 0.01 if consec_losses < 3 else 0.005
        raw = balance * risk_pct
        fee = raw * (self.bybit_fee * 2)
        return max(round(raw - fee, 4), 5.0)

    def run(self, symbol: str, timeframe: str, days: int) -> BacktestResult:
        """Jalankan simulasi backtest lengkap."""
        df = self.fetch_ohlcv(symbol, timeframe, days)
        df = generate_signals(df)

        capital = self.initial_capital
        peak = capital
        trades: List[Trade] = []
        consec_losses = 0
        balance_curve = [capital]

        in_position = False
        entry_price = 0.0
        entry_time = ""
        position_side = ""
        sl_price = 0.0
        tp_price = 0.0
        size_usd = 0.0

        for i in range(1, len(df)):
            row = df.iloc[i]

            if in_position:
                hit_sl = (position_side == "BUY" and row["low"] <= sl_price) or \
                         (position_side == "SELL" and row["high"] >= sl_price)
                hit_tp = (position_side == "BUY" and row["high"] >= tp_price) or \
                         (position_side == "SELL" and row["low"] <= tp_price)

                if hit_sl or hit_tp:
                    exit_price = sl_price if hit_sl else tp_price
                    pnl_raw = (exit_price - entry_price) / entry_price
                    if position_side == "SELL":
                        pnl_raw = -pnl_raw
                    fee = size_usd * (self.bybit_fee * 2)
                    pnl_usd = round(size_usd * pnl_raw - fee, 4)
                    pnl_pct = round(pnl_usd / capital * 100, 4)

                    capital = round(capital + pnl_usd, 4)
                    if capital > peak:
                        peak = capital
                    consec_losses = 0 if pnl_usd > 0 else consec_losses + 1

                    trades.append(Trade(
                        entry_time=entry_time,
                        exit_time=str(row["datetime"]),
                        symbol=symbol,
                        action=position_side,
                        entry_price=entry_price,
                        exit_price=exit_price,
                        size_usd=size_usd,
                        pnl_usd=pnl_usd,
                        pnl_pct=pnl_pct,
                        fee_usd=fee,
                        is_win=(pnl_usd > 0)
                    ))
                    balance_curve.append(capital)
                    in_position = False

                    if capital <= 0:
                        logger.warning("💀 Modal habis — backtest dihentikan.")
                        break
                    continue

            # Entry signal
            if not in_position and row["signal"] in ("BUY", "SELL"):
                size_usd = self._calc_position_size(capital, peak, consec_losses)
                if size_usd <= 0:
                    continue

                atr = row["atr"]
                entry_price = row["close"]
                entry_time = str(row["datetime"])
                position_side = row["signal"]

                if position_side == "BUY":
                    sl_price = entry_price - (atr * self.SL_ATR_MULT)
                    tp_price = entry_price + (atr * self.TP_ATR_MULT)
                else:
                    sl_price = entry_price + (atr * self.SL_ATR_MULT)
                    tp_price = entry_price - (atr * self.TP_ATR_MULT)

                in_position = True

        # Tutup posisi yang masih terbuka di akhir data
        if in_position and trades:
            last_price = df.iloc[-1]["close"]
            pnl_raw = (last_price - entry_price) / entry_price
            if position_side == "SELL":
                pnl_raw = -pnl_raw
            fee = size_usd * (self.bybit_fee * 2)
            pnl_usd = round(size_usd * pnl_raw - fee, 4)
            capital = round(capital + pnl_usd, 4)
            trades.append(Trade(
                entry_time=entry_time,
                exit_time=str(df.iloc[-1]["datetime"]),
                symbol=symbol, action=position_side,
                entry_price=entry_price, exit_price=last_price,
                size_usd=size_usd, pnl_usd=pnl_usd,
                pnl_pct=round(pnl_usd / self.initial_capital * 100, 4),
                fee_usd=fee, is_win=(pnl_usd > 0)
            ))

        # Hitung statistik
        n = len(trades)
        wins = sum(1 for t in trades if t.is_win)
        losses = n - wins
        total_fees = sum(t.fee_usd for t in trades)
        total_return = round((capital - self.initial_capital) / self.initial_capital * 100, 2)
        avg_pnl = round(sum(t.pnl_usd for t in trades) / n, 4) if n > 0 else 0

        # Max drawdown dari balance curve
        peak_curve = balance_curve[0]
        max_dd = 0.0
        for b in balance_curve:
            if b > peak_curve:
                peak_curve = b
            dd = (peak_curve - b) / peak_curve * 100 if peak_curve > 0 else 0
            if dd > max_dd:
                max_dd = dd

        # Sharpe Ratio sederhana (harian)
        if len(balance_curve) > 1:
            returns = [(balance_curve[i] - balance_curve[i-1]) / balance_curve[i-1]
                       for i in range(1, len(balance_curve))]
            avg_r = sum(returns) / len(returns) if returns else 0
            std_r = (sum((r - avg_r)**2 for r in returns) / len(returns))**0.5 if len(returns) > 1 else 1e-10
            sharpe = round((avg_r / std_r) * math.sqrt(252) if std_r > 0 else 0, 2)
        else:
            sharpe = 0.0

        return BacktestResult(
            symbol=symbol,
            timeframe=timeframe,
            period_days=days,
            initial_capital=self.initial_capital,
            final_capital=round(capital, 2),
            total_return_pct=total_return,
            total_trades=n,
            winning_trades=wins,
            losing_trades=losses,
            win_rate_pct=round(wins / n * 100, 1) if n > 0 else 0,
            max_drawdown_pct=round(max_dd, 2),
            avg_pnl_per_trade=avg_pnl,
            total_fees_paid=round(total_fees, 4),
            sharpe_ratio=sharpe,
            trades=trades
        )


# ==============================================================================
# REPORTER
# ==============================================================================

def print_report(result: BacktestResult):
    """Cetak laporan backtest ke konsol."""
    sep = "=" * 60
    print(f"\n{sep}")
    print(f"  📊 AXIOM BACKTEST REPORT")
    print(sep)
    print(f"  Symbol     : {result.symbol}")
    print(f"  Timeframe  : {result.timeframe}  |  Periode: {result.period_days} hari")
    print(f"  Modal Awal : ${result.initial_capital:,.2f}")
    print(f"  Modal Akhir: ${result.final_capital:,.2f}")
    print(f"  Total Return: {result.total_return_pct:+.2f}%")
    print(sep)
    print(f"  Total Trade : {result.total_trades}")
    print(f"  Win / Loss  : {result.winning_trades} / {result.losing_trades}")
    print(f"  Win Rate    : {result.win_rate_pct:.1f}%")
    print(f"  Avg PnL/Trade: ${result.avg_pnl_per_trade:+.4f}")
    print(f"  Max Drawdown: {result.max_drawdown_pct:.2f}%")
    print(f"  Sharpe Ratio: {result.sharpe_ratio}")
    print(f"  Total Fee   : ${result.total_fees_paid:.4f}")
    print(sep)

    # Penilaian strategi
    print("\n  📋 ASURA AUDIT:")
    if result.win_rate_pct >= 55:
        print(f"  ✅ Win Rate {result.win_rate_pct}% — Acceptable")
    else:
        print(f"  ⚠️  Win Rate {result.win_rate_pct}% — Di bawah threshold 55%")

    if result.max_drawdown_pct <= 15:
        print(f"  ✅ Max Drawdown {result.max_drawdown_pct}% — Dalam batas guillotine")
    else:
        print(f"  🚨 Max Drawdown {result.max_drawdown_pct}% — MELEBIHI batas 15%! Jangan live.")

    if result.sharpe_ratio >= 1.0:
        print(f"  ✅ Sharpe Ratio {result.sharpe_ratio} — Risk-adjusted return bagus")
    else:
        print(f"  ⚠️  Sharpe Ratio {result.sharpe_ratio} — Return tidak sepadan dengan risiko")

    verdict = "✅ LAYAK DILANJUTKAN KE PAPER TRADE" if (
        result.win_rate_pct >= 55
        and result.max_drawdown_pct <= 15
        and result.total_return_pct > 0
    ) else "🚨 STRATEGI PERLU DIOPTIMASI SEBELUM PAPER TRADE"
    print(f"\n  VERDICT: {verdict}")
    print(sep + "\n")


def save_report(result: BacktestResult, output_dir: str = "logs"):
    """Simpan laporan dan daftar trade ke file JSON."""
    os.makedirs(output_dir, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    filename = f"{output_dir}/backtest_{result.symbol.replace('/', '')}_{result.timeframe}_{ts}.json"

    data = {
        "summary": {
            "symbol": result.symbol,
            "timeframe": result.timeframe,
            "period_days": result.period_days,
            "initial_capital": result.initial_capital,
            "final_capital": result.final_capital,
            "total_return_pct": result.total_return_pct,
            "total_trades": result.total_trades,
            "win_rate_pct": result.win_rate_pct,
            "max_drawdown_pct": result.max_drawdown_pct,
            "sharpe_ratio": result.sharpe_ratio,
            "total_fees_paid": result.total_fees_paid,
        },
        "trades": [t.__dict__ for t in result.trades]
    }
    with open(filename, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    logger.info(f"💾 Laporan disimpan: {filename}")
    return filename


# ==============================================================================
# MULTI-SYMBOL SCAN
# ==============================================================================

def run_portfolio_scan(symbols: List[str], timeframe: str = "15m",
                       days: int = 30, capital: float = 213.0):
    """Jalankan backtest untuk beberapa simbol sekaligus — simulasi C4 Dynamic Alpha."""
    engine = BacktestEngine(initial_capital=capital)
    results = []
    print(f"\n🔍 Portfolio Scan: {len(symbols)} simbol | {timeframe} | {days} hari")
    for sym in symbols:
        try:
            r = engine.run(sym, timeframe, days)
            results.append(r)
            print(f"  {sym:15} | Return: {r.total_return_pct:+7.2f}% | "
                  f"WR: {r.win_rate_pct:.1f}% | DD: {r.max_drawdown_pct:.1f}% | "
                  f"Trades: {r.total_trades}")
        except Exception as e:
            print(f"  {sym:15} | ERROR: {e}")

    # Ranking berdasarkan Sharpe
    results.sort(key=lambda x: x.sharpe_ratio, reverse=True)
    print("\n🏆 RANKING (by Sharpe Ratio):")
    for i, r in enumerate(results, 1):
        print(f"  {i}. {r.symbol} — Sharpe: {r.sharpe_ratio} | Return: {r.total_return_pct:+.2f}%")
    return results


# ==============================================================================
# ENTRY POINT
# ==============================================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="AXIOM Backtest Framework")
    parser.add_argument("--symbol", default="BTC/USDT", help="Trading pair (default: BTC/USDT)")
    parser.add_argument("--days", type=int, default=30, help="Jumlah hari historis (default: 30)")
    parser.add_argument("--timeframe", default="15m", help="Timeframe candle (default: 15m)")
    parser.add_argument("--capital", type=float, default=213.0, help="Modal awal USD (default: 213)")
    parser.add_argument("--portfolio", action="store_true", help="Jalankan scan multi-simbol")
    args = parser.parse_args()

    if args.portfolio:
        # Portofolio dari 11_Mythos_Strategic_Portfolio.md
        symbols = [
            "BTC/USDT", "ETH/USDT", "SOL/USDT",
            "TAO/USDT", "FET/USDT",
            "TIA/USDT", "UNI/USDT",
        ]
        run_portfolio_scan(symbols, args.timeframe, args.days, args.capital)
    else:
        engine = BacktestEngine(initial_capital=args.capital)
        result = engine.run(args.symbol, args.timeframe, args.days)
        print_report(result)
        save_report(result)
