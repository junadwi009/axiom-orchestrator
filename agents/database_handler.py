import os
import psycopg2
from psycopg2.extras import Json
from psycopg2 import OperationalError
from dotenv import load_dotenv
import logging

load_dotenv()
logger = logging.getLogger(__name__)


class DatabaseHandler:
    """
    THE SCRIBE: Jembatan Database OPENCLAW.
    [FIXED V2]:
    - BUGFIX: Indentation error pada save_knowledge diperbaiki
    - BUGFIX: ON CONFLICT clause disesuaikan dengan constraint unik (entity_source, pattern_name)
    - ADDED: Auto-reconnect jika koneksi PostgreSQL terputus
    - ADDED: Try/except di setiap public method
    - ADDED: get_trade_history() untuk kebutuhan audit Kai & Asura
    """

    def __init__(self):
        self.conn = None
        self.cursor = None
        self._connect()

    def _connect(self):
        """Membuka koneksi ke PostgreSQL dengan error handling."""
        try:
            self.conn = psycopg2.connect(
                host=os.getenv("DB_HOST", "axiom_db"),
                database=os.getenv("DB_NAME", "axiom_memories"),
                user=os.getenv("DB_USER", "aru_admin"),
                password=os.getenv("DB_PASSWORD", "rahasia_aru_009"),
                connect_timeout=5
            )
            self.conn.autocommit = True
            self.cursor = self.conn.cursor()
            logger.info("🗄️ [DATABASE] Koneksi ke PostgreSQL berhasil.")
        except OperationalError as e:
            logger.error(f"❌ [DATABASE] Gagal konek ke PostgreSQL: {e}")
            self.conn = None
            self.cursor = None

    def _ensure_connection(self) -> bool:
        """Auto-reconnect jika koneksi terputus. Return True jika siap."""
        if self.conn is None or self.conn.closed:
            logger.warning("⚠️ [DATABASE] Koneksi terputus, mencoba reconnect...")
            self._connect()
        return self.cursor is not None

    # --- KEKUASAAN ARES ---
    def save_market_pulse(self, data: dict):
        """Simpan hasil scan AresAnalyzer ke tabel ares_market_scans."""
        if not self._ensure_connection():
            return
        try:
            sql = """
                INSERT INTO ares_market_scans
                    (symbol, current_price, volatility_spread, liquidity_gap,
                     best_bid, best_ask, raw_ohlcv_snapshot)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
            """
            params = (
                data.get("symbol"),
                data.get("current_price"),
                data.get("spread_pct"),
                data.get("est_slippage_pct"),
                data.get("best_bid"),
                data.get("best_ask"),
                Json(data.get("raw_ohlcv", {}))
            )
            self.cursor.execute(sql, params)
            logger.info(f"✅ [DATABASE] Market pulse {data.get('symbol')} diarsipkan.")
        except Exception as e:
            logger.error(f"❌ [DATABASE] Gagal simpan market pulse: {e}")

    # --- KEKUASAAN KAI ---
    def save_kai_audit(self, day: int, actual: float, expected: float,
                       opex: float = 0.0, note: str = ""):
        """Simpan audit harian KaiBudgeting ke kai_ledger."""
        if not self._ensure_connection():
            return
        try:
            deficit_surplus = actual - expected
            on_track = actual >= expected
            sql = """
                INSERT INTO kai_ledger
                    (day_count, actual_balance, expected_balance,
                     deficit_surplus, opex_cost, is_compounding_on_track, audit_log)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (day_count) DO UPDATE
                    SET actual_balance          = EXCLUDED.actual_balance,
                        deficit_surplus         = EXCLUDED.deficit_surplus,
                        is_compounding_on_track = EXCLUDED.is_compounding_on_track,
                        audit_log               = EXCLUDED.audit_log
            """
            self.cursor.execute(sql, (day, actual, expected,
                                      deficit_surplus, opex, on_track, note))
            logger.info(f"⚖️ [DATABASE] Audit Kai Hari ke-{day} tersimpan. On Track: {on_track}")
        except Exception as e:
            logger.error(f"❌ [DATABASE] Gagal simpan kai audit: {e}")

    # --- PENGETAHUAN DEWAN (KNOWLEDGE BASE) ---
    def save_knowledge(self, source: str, pattern_name: str, content: str,
                       data=None, summary: str = "",
                       confidence: float = 100.0, file_path: str = ""):
        """
        Menyimpan atau memperbarui protokol agen ke knowledge_base.
        [FIXED]: Indentation error diperbaiki. ON CONFLICT menggunakan
        constraint (entity_source, pattern_name) yang benar.
        """
        if not self._ensure_connection():
            return
        try:
            sql = """
                INSERT INTO knowledge_base
                    (entity_source, pattern_name, protocol_content,
                     pattern_data, logic_summary, confidence_score, file_path)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (entity_source, pattern_name) DO UPDATE
                    SET protocol_content = EXCLUDED.protocol_content,
                        logic_summary    = EXCLUDED.logic_summary,
                        last_synced      = CURRENT_TIMESTAMP
            """
            self.cursor.execute(sql, (
                source, pattern_name, content,
                Json(data) if data else None,
                summary, confidence, file_path
            ))
            logger.info(f"🧠 [DATABASE] Pola '{pattern_name}' dari {source} diserap ke memori.")
        except Exception as e:
            logger.error(f"❌ [DATABASE] Gagal simpan knowledge '{pattern_name}': {e}")

    def get_trade_history(self, limit: int = 50) -> list:
        """Ambil riwayat audit Kai terakhir untuk review Asura."""
        if not self._ensure_connection():
            return []
        try:
            self.cursor.execute(
                "SELECT * FROM kai_ledger ORDER BY created_at DESC LIMIT %s",
                (limit,)
            )
            return self.cursor.fetchall()
        except Exception as e:
            logger.error(f"❌ [DATABASE] Gagal ambil trade history: {e}")
            return []

    def close(self):
        """Menutup koneksi database dengan aman."""
        if self.cursor:
            self.cursor.close()
        if self.conn and not self.conn.closed:
            self.conn.close()
        logger.info("🗄️ [DATABASE] Koneksi ditutup.")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    db = DatabaseHandler()
    if db.conn:
        print("✅ Koneksi database OK.")
    db.close()
