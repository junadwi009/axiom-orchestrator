import os
import sys
import json
import re
import logging
from datetime import datetime
import autogen
import redis
from dotenv import load_dotenv

from agents.ares_analyzer import AresAnalyzer
from agents.kai_budgeting import KaiBudgeting

load_dotenv()
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler("logs/orchestrator.log", encoding="utf-8")
    ]
)
logger = logging.getLogger("Orchestrator")


class SovereignOrchestrator:
    """
    OTAK UTAMA AXIOM (V4 - FIXED).
    [FIXED]:
    - BUGFIX: Field signal diseragamkan: 'size_usd' (bukan 'amount') agar
              cocok dengan yang dibaca bot.py Executioner
    - BUGFIX: JSON parser sekarang menggunakan regex, tidak bisa ditipu
              oleh narasi LLM yang membungkus JSON
    - BUGFIX: Real market intel dari ares_analyzer (bukan string palsu)
              diinjeksikan ke prompt dewan
    - ADDED: Logging ke file logs/orchestrator.log
    - ADDED: Feedback loop PnL dari Redis ke Kai setelah trade selesai
    """

    def __init__(self):
        logger.info("🧠 [ORCHESTRATOR] Membangkitkan 8 Entitas Dewan Bayangan...")

        self.redis = redis.from_url(
            os.getenv("REDIS_URL", "redis://axiom_redis:6379"),
            decode_responses=True
        )

        self.ares_tool = AresAnalyzer()
        self.kai_tool = KaiBudgeting()

        # Model Config
        self.config_h3 = [{
            "model": "nousresearch/hermes-3-llama-3.1-70b",
            "api_key": os.getenv("OPENROUTER_API_KEY"),
            "base_url": "https://openrouter.ai/api/v1"
        }]
        self.config_h4 = [{
            "model": "nousresearch/hermes-4-70b",
            "api_key": os.getenv("OPENROUTER_API_KEY"),
            "base_url": "https://openrouter.ai/api/v1"
        }]

        self.llm_config_h3 = {"config_list": self.config_h3, "temperature": 0.4}
        self.llm_config_h4 = {"config_list": self.config_h4, "temperature": 0.1}

        self._initialize_council()

    def _get_knowledge(self, filename: str) -> str:
        """Menyuntikkan isi file .md ke kognisi agen dari folder knowledge."""
        path = os.path.join("knowledge", filename)
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                return f"\n\n[SUPPLEMENTAL_KNOWLEDGE]:\n{f.read()}"
        return ""

    def _initialize_council(self):
        """Inisialisasi 8 Agen Dewan Bayangan."""
        self.violet = autogen.AssistantAgent(
            name="Violet",
            system_message="Sovereign Interface. Penasihat Utama. Penafsir kehendak Aru009." + self._get_knowledge("violet.md"),
            llm_config=self.llm_config_h3
        )
        self.asura = autogen.AssistantAgent(
            name="Asura",
            system_message="Auditor Utama. Eksekutor Protokol Null. Jika probabilitas gagal >10%, veto." + self._get_knowledge("asura.md"),
            llm_config=self.llm_config_h3
        )
        self.ares = autogen.AssistantAgent(
            name="Ares",
            system_message="Alpha Hunter. Analisis Order Book dan RSI. Beri rekomendasi BUY/SELL/HOLD." + self._get_knowledge("ares.md"),
            llm_config=self.llm_config_h4
        )
        self.kai = autogen.AssistantAgent(
            name="Kai",
            system_message="CFO. Hitung margin, drawdown, dan fee. Konfirmasi size_usd yang aman." + self._get_knowledge("kai.md"),
            llm_config=self.llm_config_h4
        )
        self.thanatos = autogen.AssistantAgent(
            name="Thanatos",
            system_message="SRE & Failover. Pantau kesehatan sistem." + self._get_knowledge("thanatos.md"),
            llm_config=self.llm_config_h3
        )
        self.atlas = autogen.AssistantAgent(
            name="Atlas",
            system_message="Cloud Architect. Pastikan infrastruktur dan latensi optimal." + self._get_knowledge("atlas.md"),
            llm_config=self.llm_config_h3
        )
        self.eve = autogen.AssistantAgent(
            name="Eve",
            system_message="Data Scientist & Analyst. Evaluasi pola dan statistik pasar." + self._get_knowledge("eve.md"),
            llm_config=self.llm_config_h3
        )
        self.nero = autogen.AssistantAgent(
            name="Nero",
            system_message="Security & Anonimitas. Pantau anomali dan risiko keamanan." + self._get_knowledge("nero.md"),
            llm_config=self.llm_config_h3
        )

        self.user_proxy = autogen.UserProxyAgent(
            name="Aru009_Will",
            human_input_mode="NEVER",
            max_consecutive_auto_reply=10,
            is_termination_msg=lambda x: "EXECUTE_OPENCLAW" in x.get("content", "")
            or "HOLD_CONFIRMED" in x.get("content", "")
        )

        self.council_map = {
            "violet": self.violet, "asura": self.asura,
            "ares": self.ares, "kai": self.kai,
            "thanatos": self.thanatos, "atlas": self.atlas,
            "eve": self.eve, "nero": self.nero
        }

    def _intelligence_router(self, command: str) -> list:
        """Memilih agen relevan berdasarkan keyword untuk efisiensi token."""
        selected = {"violet", "asura"}  # Selalu hadir
        cmd = command.lower()
        mapping = {
            "kripto": {"ares", "kai"}, "market": {"ares"}, "modal": {"kai"},
            "cuan": {"ares", "kai"}, "vps": {"atlas", "thanatos"},
            "keamanan": {"thanatos", "nero"}, "infra": {"atlas"},
            "analisis": {"ares", "eve"}, "pattern": {"eve"}
        }
        for key, agents in mapping.items():
            if key in cmd:
                selected.update(agents)
        return [self.council_map[name] for name in selected]

    def _parse_signal_from_debate(self, chat_history: list) -> dict | None:
        """
        [FIXED] Mengekstrak JSON sinyal dari debat menggunakan regex.
        Lebih robust dari sebelumnya yang mudah gagal jika LLM menambahkan narasi.
        Return dict sinyal atau None jika tidak ditemukan.
        """
        full_text = " ".join(
            msg.get("content", "") for msg in chat_history
            if isinstance(msg.get("content"), str)
        )

        # Cari blok JSON dengan regex — handles ```json ... ``` maupun JSON polos
        json_pattern = re.compile(
            r'\{[^{}]*"action"\s*:\s*"(?:BUY|SELL|HOLD)"[^{}]*\}',
            re.IGNORECASE | re.DOTALL
        )
        matches = json_pattern.findall(full_text)

        # Ambil match terakhir (keputusan final dewan)
        for raw in reversed(matches):
            try:
                signal = json.loads(raw)
                if signal.get("action") in ("BUY", "SELL", "HOLD"):
                    return signal
            except json.JSONDecodeError:
                continue

        logger.warning("⚠️ [ORCHESTRATOR] Tidak ada JSON sinyal valid ditemukan dalam debat.")
        return None

    def _process_pnl_feedback(self):
        """
        [NEW] Membaca hasil eksekusi dari Redis dan memberitahu Kai.
        Bot.py mendorong notifikasi ke 'axiom_pnl_results' setelah order selesai.
        """
        while True:
            result = self.redis.lpop("axiom_pnl_results")
            if not result:
                break
            try:
                data = json.loads(result)
                self.kai_tool.record_trade_result(
                    symbol=data.get("symbol", ""),
                    action=data.get("action", ""),
                    pnl_usd=data.get("pnl_usd", 0.0),
                    new_balance=data.get("new_balance", self.kai_tool.initial_capital)
                )
            except Exception as e:
                logger.warning(f"⚠️ [KAI FEEDBACK] Gagal proses PnL result: {e}")

    def run_debate(self, symbol: str = "BTC/USDT", current_balance: float = 213.0):
        """
        Menjalankan satu siklus debat kedaulatan penuh.
        """
        # 0. Proses feedback PnL dari trade sebelumnya
        self._process_pnl_feedback()

        # 1. Data pasar nyata dari Ares
        market_data = self.ares_tool.get_market_pulse(symbol)
        if "error" in market_data:
            logger.error(f"⚠️ [ASURA VETO] Data pasar error: {market_data['error']}")
            return

        # 2. Validasi modal dari Kai
        allowed_margin = self.kai_tool.calculate_position_size(current_balance)
        if allowed_margin <= 0:
            logger.critical("💀 [KAI] Drawdown kritis. Sinyal dihentikan.")
            return

        # 3. Susun prompt dengan data NYATA (bukan hardcoded)
        intel = market_data.get("real_intel", {})
        rsi_info = f"RSI(14h)={intel.get('rsi_14h', 'N/A')} [{intel.get('rsi_signal', 'N/A')}]"
        vol_info = f"Volume24h=${intel.get('volume_24h_usd', 0):,.0f}"
        chg_info = f"Perubahan24h={intel.get('change_24h_pct', 0)}%"

        logger.info(f"⚖️ [ASURA] Menjangkar Realita. {symbol} | Risk: {market_data['risk_level']}")

        anchored_command = f"""
[KONTEKS PASAR REAL-TIME — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}]:
- Simbol        : {symbol}
- Harga Terkini : ${market_data['current_price']}
- Spread        : {market_data['spread_pct']}%
- Est. Slippage : {market_data['est_slippage_pct']}%
- Risk Level    : {market_data['risk_level']}
- {rsi_info}
- {vol_info}
- {chg_info}
- High/Low 24h  : ${intel.get('high_24h', 'N/A')} / ${intel.get('low_24h', 'N/A')}

[ANGGARAN DEWAN]:
- Margin Diizinkan Kai  : ${allowed_margin}
- Saldo Saat Ini        : ${current_balance}
- Consecutive Losses    : {self.kai_tool.consecutive_losses}

[TITAH]:
Debatkan apakah kita harus mengeksekusi order sekarang untuk target 2% hari ini.
Ares: analisis RSI dan slippage. Kai: konfirmasi size_usd={allowed_margin}.
Asura: veto jika ada keraguan >10%.

Jika sepakat BELI atau JUAL, akhiri dengan JSON persis seperti ini lalu kata EXECUTE_OPENCLAW:
{{"action": "BUY", "symbol": "{symbol}", "size_usd": {allowed_margin}, "reason": "..."}}

Jika HOLD, akhiri dengan:
{{"action": "HOLD", "symbol": "{symbol}", "size_usd": 0, "reason": "..."}}
lalu kata HOLD_CONFIRMED.
""".strip()

        # 4. Routing agen aktif
        active_agents = self._intelligence_router(f"kripto analisis {symbol}")
        active_agents.append(self.user_proxy)
        logger.info(f"📡 [ROUTER] Agen aktif: {[a.name for a in active_agents if a.name != 'Aru009_Will']}")

        # 5. Debat
        groupchat = autogen.GroupChat(agents=active_agents, messages=[], max_round=10)
        manager = autogen.GroupChatManager(groupchat=groupchat, llm_config=self.llm_config_h3)

        logger.info("🔥 [ORCHESTRATOR] Sidang Dewan dimulai...")
        chat_result = self.user_proxy.initiate_chat(manager, message=anchored_command)

        # 6. Parse dan push sinyal
        signal = self._parse_signal_from_debate(chat_result.chat_history)

        if signal and signal.get("action") in ("BUY", "SELL"):
            logger.info(
                f"🚀 [ARES] Keputusan Final: {signal['action']} {signal['symbol']} "
                f"size_usd=${signal.get('size_usd', 0)}"
            )
            # R6: axiom is observer-only — no longer push to bybit_execution_queue.
            # crypto-bot generates and executes signals autonomously via its own pipeline.
            # axiom intervenes via Channel A/B/C (see ARCHITECTURE.md §4.2, INTEGRATION_GUIDE.md §3).
        elif signal and signal.get("action") == "HOLD":
            logger.info("🛡️ [ASURA] Keputusan: HOLD. Ke fase observasi.")
        else:
            logger.warning("❌ [ORCHESTRATOR] Tidak ada keputusan valid. Tidak ada sinyal dikirim.")

        # 7. Log session summary Kai
        summary = self.kai_tool.get_session_summary()
        logger.info(f"📊 [KAI SESSION] {summary}")

    # ------------------------------------------------------------------
    # M1 SUPPORT: heartbeat + command handler stub
    # ------------------------------------------------------------------

    def write_heartbeat(self):
        """
        Atomic write of ISO 8601 timestamp ke /app/logs/heartbeat.
        Compose healthcheck (lihat docker-compose.yaml) cek file ini di-update <2 menit.
        """
        try:
            heartbeat_path = "/app/logs/heartbeat"
            tmp_path = heartbeat_path + ".tmp"
            with open(tmp_path, "w") as f:
                f.write(datetime.utcnow().isoformat() + "Z")
            os.replace(tmp_path, heartbeat_path)
        except Exception as e:
            logger.warning(f"Heartbeat write failed: {e}")

    def handle_command(self, command: dict):
        """
        M1 stub command handler. Log received + ack ke axiom:command_response_queue.
        Phase 3+ akan invoke AutoGen Council saat command type='council_deliberate'.
        """
        cmd_type = command.get("type", "unknown")
        cmd_id = command.get("id", "no-id")
        logger.info(f"📩 [ORCHESTRATOR] Received command type={cmd_type} id={cmd_id}")

        response = {
            "id": cmd_id,
            "status": "received",
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "note": "M1 stub — full handler in Phase 3"
        }
        try:
            self.redis.lpush("axiom:command_response_queue", json.dumps(response))
        except Exception as e:
            logger.error(f"Failed to ack command {cmd_id}: {e}")


if __name__ == "__main__":
    import signal as os_signal  # aliased to avoid collision with local `signal` var in run_debate

    brain = SovereignOrchestrator()

    def handle_sigterm(signum, frame):
        logger.info(f"Received signal {signum}, shutting down gracefully")
        brain.write_heartbeat()
        sys.exit(0)

    os_signal.signal(os_signal.SIGTERM, handle_sigterm)
    os_signal.signal(os_signal.SIGINT, handle_sigterm)

    logger.info("🧠 [SYSTEM] axiom_brain ready, listening on axiom:command_queue")

    while True:
        try:
            result = brain.redis.blpop("axiom:command_queue", timeout=5)
            if result:
                _, payload = result
                command = json.loads(payload.decode() if isinstance(payload, bytes) else payload)
                brain.handle_command(command)
        except json.JSONDecodeError as e:
            logger.error(f"Command parse error: {e}")
        except Exception as e:
            logger.error(f"Listener error: {e}", exc_info=True)

        brain.write_heartbeat()
