import re
import unittest
from pathlib import Path


EA_PATH = (
    Path(__file__).parents[1]
    / "MQL5"
    / "Experts"
    / "XAUUSD_M5_Reversal_Alert_EA.mq5"
)


class PushPlusEaContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = EA_PATH.read_text(encoding="utf-8")

    def test_is_an_ea_with_timer_not_an_indicator(self):
        self.assertIn("#property strict", self.source)
        self.assertIn("int OnInit()", self.source)
        self.assertIn("void OnTimer()", self.source)
        self.assertIn("void OnDeinit(", self.source)
        self.assertNotIn("OnCalculate(", self.source)
        self.assertNotIn("#property indicator_", self.source)

    def test_has_pushplus_runtime_inputs_without_a_real_token(self):
        self.assertIn("input bool   InpEnablePushPlus", self.source)
        self.assertIn('input string InpPushPlusToken = "";', self.source)
        self.assertIn(
            'input string InpPushPlusUrl = "https://www.pushplus.plus/send";',
            self.source,
        )
        self.assertIn('input string InpPushPlusChannel = "wechat";', self.source)
        self.assertIn('input string InpPushPlusTemplate = "txt";', self.source)
        self.assertIn("input int    InpPushPlusTimeoutMs = 5000;", self.source)
        self.assertIn("input bool   InpSendStartupTest", self.source)

    def test_defines_message_and_transport_boundaries(self):
        for signature in (
            "string JsonEscape(",
            "string BuildReversalTitle(",
            "string BuildReversalContent(",
            "bool SendPushPlus(",
            "void EmitConfirmedReversal(",
        ):
            with self.subTest(signature=signature):
                self.assertIn(signature, self.source)
        self.assertIn("WebRequest(", self.source)
        self.assertIn("application/json; charset=utf-8", self.source)
        self.assertIn("CP_UTF8", self.source)

    def test_json_contains_required_fields_and_escapes(self):
        for field in ('\\"token\\"', '\\"title\\"', '\\"content\\"',
                      '\\"template\\"', '\\"channel\\"'):
            with self.subTest(field=field):
                self.assertIn(field, self.source)
        for escape in ('"\\\\"', '"\\\\\\""', '"\\\\n"', '"\\\\r"', '"\\\\t"'):
            with self.subTest(escape=escape):
                self.assertIn(escape, self.source)

    def test_reversal_message_contains_approved_semantics(self):
        for text in (
            "空转多提醒",
            "多转空提醒",
            "品种：",
            "周期：M5",
            "方向：",
            "服务器时间：",
            "EMA：",
            "Supertrend：",
            "RSI：",
            "确认时间：",
        ):
            with self.subTest(text=text):
                self.assertIn(text, self.source)

    def test_token_is_not_logged_displayed_or_put_in_url(self):
        forbidden_patterns = (
            r"Print(?:Format)?\s*\([^;]*InpPushPlusToken",
            r"Alert\s*\([^;]*InpPushPlusToken",
            r"SetLabel\s*\([^;]*InpPushPlusToken",
            r"InpPushPlusUrl\s*\+\s*InpPushPlusToken",
        )
        for pattern in forbidden_patterns:
            with self.subTest(pattern=pattern):
                self.assertIsNone(re.search(pattern, self.source, re.DOTALL))

    def test_contains_no_trading_api(self):
        for forbidden in (
            "#include <Trade/",
            "OrderSend",
            "CTrade",
            "PositionOpen",
            "trade.Buy",
            "trade.Sell",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, self.source)


if __name__ == "__main__":
    unittest.main()
