import unittest
from pathlib import Path


SOURCE = (
    Path(__file__).parents[1]
    / "MQL5"
    / "Indicators"
    / "XAUUSD_M5_Reversal_Alert.mq5"
).read_text(encoding="utf-8")


class MqlContractTests(unittest.TestCase):
    def test_panel_prefix_is_unique_per_instance(self):
        self.assertIn("g_panel_prefix", SOURCE)
        self.assertIn("GetMicrosecondCount()", SOURCE)
        self.assertNotIn('const string PANEL_PREFIX = "XAU_M5_RA_";', SOURCE)

    def test_sound_warning_has_persistent_state(self):
        self.assertIn("g_warning_status", SOURCE)
        self.assertIn('g_warning_status = "声音播放失败', SOURCE)

    def test_runtime_initialization_failure_remains_retryable(self):
        self.assertIn("TryInitializeRuntime", SOURCE)
        self.assertIn("if(!g_runtime_ready)", SOURCE)

    def test_supertrend_history_scales_with_atr_period(self):
        self.assertIn("RequiredHistoryBars", SOURCE)
        self.assertNotIn("const int    COPY_BARS    = 200;", SOURCE)

    def test_source_contains_no_trading_api(self):
        for forbidden in ("OrderSend", "CTrade", "PositionOpen", "trade.Buy",
                          "trade.Sell"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, SOURCE)


if __name__ == "__main__":
    unittest.main()
