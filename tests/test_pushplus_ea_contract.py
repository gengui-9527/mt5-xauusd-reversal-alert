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

    @classmethod
    def function_source(cls, signature):
        start = cls.source.index(signature)
        brace = cls.source.index("{", start)
        depth = 0
        for index in range(brace, len(cls.source)):
            if cls.source[index] == "{":
                depth += 1
            elif cls.source[index] == "}":
                depth -= 1
                if depth == 0:
                    return cls.source[start:index + 1]
        raise AssertionError(f"unterminated function: {signature}")

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
        self.assertIn('input string InpPushPlusChannel = "app";', self.source)
        self.assertNotIn('input string InpPushPlusChannel = "wechat";', self.source)
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

    def test_reversal_message_contains_adaptive_score_breakdown(self):
        content = self.function_source("string BuildReversalContent(")
        for text in (
            "空转多提醒",
            "多转空提醒",
            "品种：",
            "周期：M5",
            "方向：",
            "服务器时间：",
            "最终评分：",
            "EMA贡献：",
            "Supertrend贡献：",
            "RSI贡献：",
            "确认时间：",
        ):
            with self.subTest(text=text):
                self.assertIn(text, self.source if text.endswith("提醒") else content)
        for legacy in ("\nEMA：", "\nSupertrend：", "\nRSI："):
            with self.subTest(legacy=legacy):
                self.assertNotIn(legacy, content)

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

    def test_startup_test_waits_for_live_snapshot_and_baseline(self):
        timer = self.source[self.source.index("void OnTimer()") :]
        self.assertIn("ReadAdaptiveSignal", timer)
        self.assertIn("AdvanceAdaptiveState", timer)
        read_pos = timer.index("ReadAdaptiveSignal")
        baseline_pos = timer.index("AdvanceAdaptiveState")
        startup_pos = timer.index("MaybeSendStartupTest")
        self.assertLess(read_pos, startup_pos)
        self.assertLess(baseline_pos, startup_pos)
        self.assertIn("if(g_confirmed_direction!=DIR_NONE)", timer)
        init = self.source[
            self.source.index("int OnInit()") : self.source.index("void OnDeinit(")
        ]
        self.assertNotIn("MaybeSendStartupTest();", init)

    def test_business_response_parser_is_strict_and_classifies_errors(self):
        self.assertIn("enum PushResponseParseResult", self.source)
        self.assertIn("PUSH_CODE_MISSING", self.source)
        self.assertIn("PUSH_CODE_INVALID", self.source)
        self.assertIn("PUSH_CODE_OK", self.source)
        self.assertIn("ParseTopLevelBusinessCode", self.source)
        self.assertIn("响应缺少业务码", self.source)
        self.assertIn("响应业务码格式无效", self.source)
        self.assertNotIn("StringToInteger(tail)", self.source)
        self.assertIn("code_found", self.source)
        self.assertIn("SkipJsonValue", self.source)
        self.assertIn("index!=length", self.source)
        self.assertIn("expect_member", self.source)
        self.assertNotIn("ch=='+'", self.source)

    def test_sound_and_pushplus_warnings_have_separate_ownership(self):
        self.assertIn("g_sound_warning", self.source)
        self.assertIn("g_push_warning", self.source)
        send = self.source[
            self.source.index("bool SendPushPlus(") :
            self.source.index("void EmitConfirmedReversal(")
        ]
        self.assertNotIn("g_sound_warning=", send)

    def test_panel_displays_signed_adaptive_score_and_confirmation_progress(self):
        panel = self.function_source("void RenderPanel()")
        for text in (
            "综合评分：",
            "EMA贡献：",
            "Supertrend贡献：",
            "RSI贡献：",
            "已确认方向：",
            "候选方向：",
            "目标确认：",
            "确认进度：",
            "剩余：",
        ):
            with self.subTest(text=text):
                self.assertIn(text, panel)
        for score in (
            "g_snapshot.total_score",
            "g_snapshot.ema_score",
            "g_snapshot.supertrend_score",
            "g_snapshot.rsi_score",
        ):
            with self.subTest(score=score):
                self.assertIn(f"SignedScore({score})", panel)
        self.assertIn("MathMax(0.0,", panel)
        self.assertIn('string pending_direction="无";', panel)

    def test_panel_interprets_score_using_maintenance_threshold(self):
        panel = self.function_source("void RenderPanel()")
        self.assertIn(
            "ScoreDirection(g_snapshot.total_score,"
            "InpDirectionMaintenanceScore)".replace(" ", ""),
            panel.replace("\n", "").replace(" ", ""),
        )
        for text in ("偏多", "偏空", "中性"):
            with self.subTest(text=text):
                self.assertIn(text, self.source)

    def test_signed_score_uses_the_rounded_text_sign(self):
        signed = self.function_source("string SignedScore(const double score)")
        self.assertIn("string formatted=DoubleToString(score,1);", signed)
        self.assertIn("StringGetCharacter(formatted,0)=='-'", signed)
        self.assertNotIn("score>=0.0", signed)

    def test_directional_pushplus_has_one_final_emission_call_site(self):
        emit = self.function_source("void EmitConfirmedReversal(")
        panel = self.function_source("void RenderPanel()")
        candidate = self.function_source(
            "bool AdvanceAdaptiveState(const double score,const ulong now_ms)"
        )
        self.assertEqual(self.source.count("SendPushPlus(title,content);"), 1)
        self.assertIn("SendPushPlus(title,content);", emit)
        self.assertIn("BuildReversalContent(", emit)
        self.assertNotIn("SendPushPlus(", panel)
        self.assertNotIn("SendPushPlus(", candidate)

    def test_adaptive_inputs_have_approved_defaults(self):
        for text in (
            "input int InpFastEmaPeriod = 7;",
            "input int InpSlowEmaPeriod = 18;",
            "input int InpAtrPeriod = 8;",
            "input double InpSupertrendMultiplier = 2.4;",
            "input int InpRsiPeriod = 9;",
            "input double InpRsiNeutralLower = 48.0;",
            "input double InpRsiNeutralUpper = 52.0;",
            "input double InpCandidateEntryScore = 55.0;",
            "input double InpDirectionMaintenanceScore = 35.0;",
            "input double InpMinimumConfirmationSeconds = 3.0;",
            "input double InpMaximumConfirmationSeconds = 10.0;",
            "input double InpEmaDistanceWeight = 25.0;",
            "input double InpEmaSlopeWeight = 10.0;",
            "input double InpSupertrendWeight = 40.0;",
            "input double InpRsiWeight = 25.0;",
            "input double InpEmaDistanceAtrScale = 0.20;",
            "input double InpEmaSlopeAtrScale = 0.08;",
            "input double InpSupertrendAtrScale = 0.50;",
        ):
            with self.subTest(text=text):
                self.assertIn(text, self.source)

    def test_adaptive_runtime_exposes_required_interfaces_and_snapshot(self):
        for signature in (
            "double ClampUnit(const double value)",
            "bool InitializeSupertrendCache()",
            "bool PreviewCurrentSupertrend(const MqlRates &bar,const double atr,double &line)",
            "bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)",
            "double RequiredConfirmationSeconds(const double score)",
            "bool AdvanceAdaptiveState(const double score,const ulong now_ms)",
        ):
            with self.subTest(signature=signature):
                self.assertIn(signature, self.source)
        self.assertIn("struct ScoreSnapshot", self.source)
        snapshot = self.source[
            self.source.index("struct ScoreSnapshot"):
            self.source.index("};", self.source.index("struct ScoreSnapshot")) + 2
        ]
        for field in (
            "ema_score",
            "supertrend_score",
            "rsi_score",
            "total_score",
            "required_seconds",
        ):
            with self.subTest(field=field):
                self.assertIn(field, snapshot)

    def test_adaptive_validation_is_bounded_finite_and_keeps_ea_loaded(self):
        validate = self.function_source("bool ValidateInputs()")
        for text in (
            "MAX_INDICATOR_PERIOD",
            "InpFastEmaPeriod>=InpSlowEmaPeriod",
            "MathIsValidNumber",
            "MathAbs(weight_sum-100.0)>1e-6",
            "InpRsiNeutralLower>=50.0",
            "InpRsiNeutralUpper<=50.0",
            "InpDirectionMaintenanceScore>=InpCandidateEntryScore",
            "InpCandidateEntryScore>100.0",
            "InpMinimumConfirmationSeconds>InpMaximumConfirmationSeconds",
            "参数错误：EMA周期",
            "参数错误：Supertrend参数",
            "参数错误：RSI参数",
            "参数错误：评分权重",
            "参数错误：评分阈值",
            "参数错误：确认时间",
            "参数错误：标准化尺度",
        ):
            with self.subTest(text=text):
                self.assertIn(text, validate)
        init = self.function_source("int OnInit()")
        self.assertIn("g_inputs_valid=ValidateInputs();", init)
        self.assertNotIn("INIT_PARAMETERS_INCORRECT", init)
        self.assertIn("return INIT_SUCCEEDED;", init)

    def test_scoring_uses_exact_formulas_and_rejects_nonfinite_data(self):
        signature = "bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)"
        self.assertIn(signature, self.source)
        scoring = self.function_source(signature)
        for text in (
            "MathIsValidNumber",
            "atr[0]<=0.0",
            "double ema_distance_denominator=InpEmaDistanceAtrScale*atr[0];",
            "double ema_slope_denominator=InpEmaSlopeAtrScale*atr[0];",
            "double supertrend_denominator=InpSupertrendAtrScale*atr[0];",
            "double ema_distance_ratio=(fast[0]-slow[0])/ema_distance_denominator;",
            "double ema_slope_ratio=(fast[0]-fast[1])/ema_slope_denominator;",
            "double supertrend_ratio=(price-supertrend_line)/supertrend_denominator;",
            "!MathIsValidNumber(ema_distance_denominator)",
            "!MathIsValidNumber(ema_slope_denominator)",
            "!MathIsValidNumber(supertrend_denominator)",
            "!MathIsValidNumber(ema_distance_ratio)",
            "!MathIsValidNumber(ema_slope_ratio)",
            "!MathIsValidNumber(supertrend_ratio)",
            "ClampUnit(ema_distance_ratio)",
            "ClampUnit(ema_slope_ratio)",
            "ClampUnit(supertrend_ratio)",
            "(rsi[0]-InpRsiNeutralUpper)/8.0",
            "(rsi[0]-InpRsiNeutralLower)/8.0",
            "MathMax(-100.0,MathMin(100.0",
        ):
            with self.subTest(text=text):
                self.assertIn(text, scoring)

    def test_read_adaptive_signal_does_not_replay_full_history_per_tick(self):
        signature = "bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)"
        self.assertIn(signature, self.source)
        scoring = self.function_source(signature)
        self.assertNotIn("RequiredHistoryBars()", scoring)
        self.assertNotRegex(scoring, r"CopyRates\s*\([^;]*\bcount\b")
        self.assertNotRegex(scoring, r"\bfor\s*\(")
        self.assertIn("CopyRates(g_symbol,PERIOD_M5,0,2", scoring)

    def test_one_decision_context_owns_reconnect_score_and_progress_decisions(self):
        signature = "bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)"
        self.assertIn(signature, self.source)
        scoring = self.function_source(signature)
        self.assertNotIn(
            "bool ReadAdaptiveSignal(ScoreSnapshot &snapshot,const MqlTick &tick)",
            self.source,
        )
        for text in (
            "if(!g_decision_tick_valid) return false;",
            "MqlTick tick=g_decision_tick;",
            "double price=tick.bid;",
            "snapshot.tick_time_msc=tick.time_msc;",
            "snapshot.server_time=(datetime)tick.time;",
            "iBarShift(g_symbol,PERIOD_M5,(datetime)tick.time,true)",
            "tick_bar_shift!=0",
            "rates[0].time",
        ):
            with self.subTest(text=text):
                self.assertIn(text, scoring)
        timer = self.function_source("void OnTimer()")
        self.assertIn("MqlTick decision_tick;", timer)
        self.assertIn("IsNewTargetTick(decision_tick)", timer)
        self.assertIn("g_decision_tick=decision_tick;", timer)
        self.assertIn("g_decision_tick_valid=true;", timer)
        self.assertIn("ReadAdaptiveSignal(s)", timer)
        self.assertIn("g_decision_tick_valid=false;", timer)
        self.assertIn("decision_tick.time_msc-g_previous_server_tick_msc", timer)
        self.assertIn(
            "g_previous_server_tick_msc=decision_tick.time_msc;",
            timer,
        )

    def test_failed_coherent_acquisition_can_retry_the_same_tick(self):
        new_tick = self.function_source("bool IsNewTargetTick(MqlTick &tick)")
        for forbidden in (
            "g_last_tick_time_msc=",
            "g_last_tick_bid=",
            "g_last_tick_ask=",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, new_tick)
        timer = self.function_source("void OnTimer()")
        self.assertIn("ReadAdaptiveSignal(s)", timer)
        self.assertIn("g_last_tick_time_msc=decision_tick.time_msc;", timer)
        read_pos = timer.index("ReadAdaptiveSignal(s)")
        mark_pos = timer.index("g_last_tick_time_msc=decision_tick.time_msc;")
        advance_pos = timer.index("AdvanceAdaptiveState(")
        self.assertLess(read_pos, mark_pos)
        self.assertLess(mark_pos, advance_pos)

    def test_post_copy_tick_stability_precedes_cache_or_score_mutation(self):
        self.assertIn(
            "bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)",
            self.source,
        )
        scoring = self.function_source(
            "bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)"
        )
        copy_pos = scoring.rindex("CopyBuffer(")
        verify_fetch_pos = scoring.index(
            "SymbolInfoTick(g_symbol,verification_tick)"
        )
        identity_pos = scoring.index(
            "verification_tick.time_msc!=tick.time_msc"
        )
        cache_pos = scoring.index("SynchronizeSupertrendCache(")
        score_pos = scoring.index("snapshot.ema_score=")
        self.assertLess(copy_pos, verify_fetch_pos)
        self.assertLess(verify_fetch_pos, identity_pos)
        self.assertLess(identity_pos, cache_pos)
        self.assertLess(cache_pos, score_pos)
        for text in (
            "verification_tick.bid!=tick.bid",
            "verification_tick.ask!=tick.ask",
            'g_status="M5报价更新，等待重试";',
            "return false;",
        ):
            with self.subTest(text=text):
                self.assertIn(text, scoring[verify_fetch_pos:cache_pos])

    def test_new_m5_history_audit_rechecks_tick_and_bar_before_classification(self):
        scoring = self.function_source(
            "bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)"
        )
        cache_pos = scoring.index("SynchronizeSupertrendCache(")
        preview_pos = scoring.index("PreviewCurrentSupertrend(", cache_pos)
        self.assertNotIn("post_cache_tick", scoring[cache_pos:preview_pos])

        audit = self.function_source(
            "SupertrendAuditResult AuditSupertrendHistory("
        )
        fetch_pos = audit.index(
            "SymbolInfoTick(g_symbol,audit_tick)"
        )
        identity_pos = audit.index(
            "audit_tick.time_msc!=g_decision_tick.time_msc", fetch_pos
        )
        bar_pos = audit.index(
            "iTime(g_symbol,PERIOD_M5,audit_bar_shift)!=current_bar.time",
            identity_pos,
        )
        compare_pos = audit.index(
            "for(int i=0;i<g_st_history_count;i++)"
        )
        self.assertLess(fetch_pos, identity_pos)
        self.assertLess(identity_pos, bar_pos)
        self.assertLess(bar_pos, compare_pos)

    def test_reconnect_reset_mutates_state_only_after_tick_stability(self):
        scoring = self.function_source(
            "bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)"
        )
        identity_pos = scoring.index(
            "verification_tick.time_msc!=tick.time_msc"
        )
        self.assertIn("if(reconnect_reset)", scoring)
        reconnect_pos = scoring.index("if(reconnect_reset)")
        reset_pos = scoring.index("ResetSignalState();", reconnect_pos)
        bar_identity_pos = scoring.index("tick_bar_shift!=0")
        cache_pos = scoring.index("SynchronizeSupertrendCache(")
        self.assertLess(identity_pos, reconnect_pos)
        self.assertLess(bar_identity_pos, reconnect_pos)
        self.assertLess(reconnect_pos, reset_pos)
        self.assertLess(reset_pos, cache_pos)
        timer = self.function_source("void OnTimer()")
        read_pos = timer.index("ReadAdaptiveSignal(s)")
        self.assertNotIn("ResetSignalState();", timer[:read_pos])
        self.assertNotIn("InitializeSupertrendCache()", timer[:read_pos])
        self.assertIn("g_decision_reconnect_reset=reconnect_reset;", timer)

    def test_supertrend_history_is_bounded_and_preview_does_not_mutate_cache(self):
        required = self.function_source("int RequiredHistoryBars()")
        self.assertIn("MAX_HISTORY_BARS", required)
        self.assertIn("InpAtrPeriod>MAX_HISTORY_BARS/10", required)
        self.assertIn("bool InitializeSupertrendCache()", self.source)
        initialize = self.function_source("bool InitializeSupertrendCache()")
        self.assertIn("CopyRates(g_symbol,PERIOD_M5,1,count", initialize)
        self.assertIn("CopyBuffer(g_atr_handle,0,1,count", initialize)
        self.assertIn(
            "bool PreviewCurrentSupertrend(const MqlRates &bar,const double atr,double &line)",
            self.source,
        )
        preview = self.function_source(
            "bool PreviewCurrentSupertrend(const MqlRates &bar,const double atr,double &line)"
        )
        for cached_name in (
            "g_st_final_upper=",
            "g_st_final_lower=",
            "g_st_long_trend=",
            "g_st_previous_close=",
            "g_st_committed_time=",
        ):
            with self.subTest(cached_name=cached_name):
                self.assertNotIn(cached_name, preview)

    def test_supertrend_history_identity_ledger_is_bounded_and_initialized(self):
        self.assertIn("struct SupertrendBarIdentity", self.source)
        identity_start = self.source.index("struct SupertrendBarIdentity")
        identity_end = self.source.index("};", identity_start)
        identity = self.source[identity_start:identity_end]
        for field in ("time", "open", "high", "low", "close", "atr"):
            with self.subTest(field=field):
                self.assertRegex(identity, rf"\b{field}\b")
        self.assertIn("SupertrendBarIdentity g_st_history[];", self.source)
        self.assertIn("int g_st_history_count=0;", self.source)

        initialize = self.function_source("bool InitializeSupertrendCache()")
        for text in (
            "SupertrendBarIdentity staged_history[];",
            "ArrayResize(staged_history,count)!=count",
            "BuildSupertrendIdentity(rates[i],atr[i],staged_history[i])",
            "PublishSupertrendCache(staged_history,count,upper,lower,long_trend,",
        ):
            with self.subTest(text=text):
                self.assertIn(text, initialize)
        publish = self.function_source("bool PublishSupertrendCache(")
        publish_pos = publish.index("g_st_history_count=count;")
        reset_pos = publish.index("ResetSignalState();")
        self.assertLess(publish_pos, reset_pos)

    def test_supertrend_audit_is_new_m5_only_and_compares_full_ledger(self):
        synchronize = self.function_source("bool SynchronizeSupertrendCache(")
        same_m5 = "if(current_bar.time==g_st_active_time)\n      return true;"
        self.assertIn(same_m5, synchronize)
        self.assertIn("if(g_st_history_count>=MAX_HISTORY_BARS)", synchronize)
        self.assertIn("AuditSupertrendHistory(", synchronize)
        self.assertIn("ST_AUDIT_MISMATCH", synchronize)
        self.assertIn("return InitializeSupertrendCache();", synchronize)
        same_m5_pos = synchronize.index(same_m5)
        audit_pos = synchronize.index("AuditSupertrendHistory(")
        self.assertLess(same_m5_pos, audit_pos)
        self.assertNotIn("CopyRates(", synchronize[:audit_pos])
        self.assertNotIn("CopyBuffer(", synchronize[:audit_pos])

        self.assertIn(
            "SupertrendAuditResult AuditSupertrendHistory(",
            self.source,
        )
        audit = self.function_source(
            "SupertrendAuditResult AuditSupertrendHistory("
        )
        for text in (
            "int audit_count=g_st_history_count+1;",
            "CopyRates(g_symbol,PERIOD_M5,1,audit_count,audit_rates)!=audit_count",
            "CopyBuffer(g_atr_handle,0,1,audit_count,audit_atr)!=audit_count",
            "for(int i=0;i<g_st_history_count;i++)",
            "MatchesSupertrendIdentity(g_st_history[i],audit_rates[i],audit_atr[i])",
            "return ST_AUDIT_MISMATCH;",
            "return ST_AUDIT_RETRY;",
            "return ST_AUDIT_MATCH;",
        ):
            with self.subTest(text=text):
                self.assertIn(text, audit)
        self.assertNotRegex(audit, r"\bg_st_[A-Za-z0-9_]*\s*=")

    def test_cache_rebuild_publishes_ledger_and_state_atomically(self):
        initialize = self.function_source("bool InitializeSupertrendCache()")
        for forbidden in (
            "ArrayResize(g_st_history",
            "g_st_history[i]=",
            "g_st_history_count=",
            "g_st_final_upper=",
            "g_st_committed_time=",
            "ResetSignalState();",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, initialize)
        self.assertIn(
            "return PublishSupertrendCache(staged_history,count,upper,lower,"
            "long_trend,previous_close,committed_time);".replace(" ", ""),
            initialize.replace("\n", "").replace(" ", ""),
        )

        publish = self.function_source("bool PublishSupertrendCache(")
        for text in (
            "ArrayResize(g_st_history,MAX_HISTORY_BARS)!=MAX_HISTORY_BARS",
            "g_st_history[i]=staged_history[i];",
            "g_st_history_count=count;",
            "g_st_final_upper=upper;",
            "g_st_committed_time=committed_time;",
            "g_st_cache_ready=true;",
            "ResetSignalState();",
        ):
            with self.subTest(text=text):
                self.assertIn(text, publish)

    def test_supertrend_audit_retries_before_cache_or_ledger_mutation(self):
        synchronize = self.function_source("bool SynchronizeSupertrendCache(")
        audit_pos = synchronize.index("AuditSupertrendHistory(")
        retry_pos = synchronize.index("if(audit_result==ST_AUDIT_RETRY)", audit_pos)
        advance_pos = synchronize.index("AdvanceSupertrendValues(", audit_pos)
        append_pos = synchronize.index(
            "g_st_history[g_st_history_count]=new_identity;", audit_pos
        )
        cache_pos = synchronize.index("g_st_final_upper=", audit_pos)
        self.assertLess(audit_pos, retry_pos)
        self.assertLess(retry_pos, advance_pos)
        self.assertLess(advance_pos, append_pos)
        self.assertLess(append_pos, cache_pos)

    def test_supertrend_rebuilds_silently_on_reconnect_and_history_change(self):
        synchronize = self.function_source("bool SynchronizeSupertrendCache(")
        for text in (
            "current_bar.time<g_st_active_time",
            "previous_bar.time!=g_st_active_time",
            "ST_AUDIT_MISMATCH",
            "g_st_history_count>=MAX_HISTORY_BARS",
            "return InitializeSupertrendCache();",
        ):
            with self.subTest(text=text):
                self.assertIn(text, synchronize)
        initialize = self.function_source("bool InitializeSupertrendCache()")
        self.assertIn("PublishSupertrendCache(", initialize)
        publish = self.function_source("bool PublishSupertrendCache(")
        self.assertIn("ResetSignalState();", publish)
        timer = self.function_source("void OnTimer()")
        self.assertIn("tick.time_msc<g_previous_server_tick_msc", timer)
        self.assertIn("g_decision_reconnect_reset=reconnect_reset;", timer)
        scoring = self.function_source(
            "bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)"
        )
        self.assertIn("g_st_cache_ready=false;", scoring)

    def test_score_direction_uses_explicit_symmetric_tolerance(self):
        self.assertIn(
            "const double SCORE_COMPARISON_TOLERANCE=1e-9;",
            self.source,
        )
        direction = self.function_source(
            "int ScoreDirection(const double score,const double threshold)"
        )
        self.assertIn(
            "score>=threshold-SCORE_COMPARISON_TOLERANCE",
            direction,
        )
        self.assertIn(
            "score<=-threshold+SCORE_COMPARISON_TOLERANCE",
            direction,
        )

    def test_runtime_cache_retry_preserves_calculating_indicator_handles(self):
        initialize = self.function_source("bool TryInitializeRuntime()")
        self.assertIn("g_atr_handle==INVALID_HANDLE", initialize)
        self.assertIn("if(!InitializeSupertrendCache()) return false;", initialize)
        self.assertNotIn(
            "if(!InitializeSupertrendCache()) { ReleaseHandles(); return false; }",
            initialize,
        )

    def test_first_cache_sync_does_not_commit_the_completed_bar_twice(self):
        synchronize = self.function_source("bool SynchronizeSupertrendCache(")
        baseline = (
            "g_st_active_time=current_bar.time;\n"
            "      return true;"
        )
        self.assertIn(baseline, synchronize)

    def test_adaptive_confirmation_uses_progress_and_explicit_timestamp_validity(self):
        self.assertIn(
            "bool AdvanceAdaptiveState(const double score,const ulong now_ms)",
            self.source,
        )
        state = self.function_source(
            "bool AdvanceAdaptiveState(const double score,const ulong now_ms)"
        )
        for text in (
            "g_confirmation_progress",
            "g_has_last_confirmation_tick",
            "RequiredConfirmationSeconds(score)",
            "active_seconds/InpMaximumConfirmationSeconds*0.5",
            "active_seconds/InpMaximumConfirmationSeconds",
            "g_confirmation_progress>=1.0",
        ):
            with self.subTest(text=text):
                self.assertIn(text, state)
        self.assertNotRegex(
            state,
            r"g_last_confirmation_tick_ms\s*(?:==|!=)\s*0",
        )
        self.assertIn("g_has_last_confirmation_tick=true;", state)

    def test_large_notification_contract(self):
        for required in (
            "input int InpLargeNotificationSeconds = 15;",
            "input bool InpEnableLargeNotification = true;",
            "input bool InpEnablePopup = false;",
            "void ShowLargeNotification(",
            "void UpdateLargeNotification(",
            "void CenterLargeNotification(",
            "void HideLargeNotification(",
            "void OnChartEvent(",
            "CHARTEVENT_OBJECT_CLICK",
            "CHARTEVENT_CHART_CHANGE",
            "LARGE_BG",
            "LARGE_TITLE",
            "LARGE_BODY",
            "LARGE_COUNTDOWN",
            "LARGE_CLOSE",
            "CHART_WIDTH_IN_PIXELS",
            "CHART_HEIGHT_IN_PIXELS",
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.source)

    def test_large_notification_contains_full_reversal_context(self):
        show_start = self.source.index("void ShowLargeNotification(")
        show_end = self.source.index("void UpdateLargeNotification(")
        show_source = self.source[show_start:show_end]
        for text in (
            "空转多",
            "多转空",
            "服务器时间",
            "最终评分：",
            "EMA贡献：",
            "Supertrend贡献：",
            "RSI贡献：",
            "PushPlus",
        ):
            with self.subTest(text=text):
                self.assertIn(text, show_source)

    def test_large_notification_adapts_and_prioritizes_close_button(self):
        for required in (
            "available_width",
            "available_height",
            "large_font_size",
            "MathMax(1,chart_width-4)",
            "MathMax(1,chart_height-4)",
            '"\\nSupertrend贡献："',
            '"\\nRSI贡献："',
            "OBJPROP_ZORDER,1",
            "OBJPROP_ZORDER,100",
            "OBJPROP_STATE,false",
            "OBJPROP_SELECTABLE,true",
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.source)

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
