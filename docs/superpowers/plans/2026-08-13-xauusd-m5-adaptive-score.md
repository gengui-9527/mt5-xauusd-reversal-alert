# XAUUSD M5 Adaptive Reversal Score Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the EA's delayed three-vote reversal rule with the approved ATR-normalized continuous score, hysteresis, adaptive 3–10 second confirmation, and incremental Supertrend runtime while preserving confirmed-only non-trading alerts.

**Architecture:** Keep the deployable EA in one MQL5 source file for simple MT5 installation, but separate its internals into indicator acquisition, incremental Supertrend, score calculation, confirmation state, presentation, and transport functions. Use a deterministic Python reference model and fixed replay fixture to test formulas and state transitions, source-contract tests to bind the MQL implementation to the approved interfaces and constants, then verify the actual EA with MetaEditor compilation and build hashes.

**Tech Stack:** MQL5 EA API, MT5 EMA/ATR/RSI handles, Python 3 `unittest` and CSV, MetaEditor 5, PushPlus HTTPS JSON API.

## Global Constraints

- Monitor the configured XAUUSD-family symbol using live `PERIOD_M5` data regardless of the attached chart.
- Default periods and thresholds are EMA 7/18, Supertrend ATR 8 × 2.4, RSI 9 with neutral zone 48–52, entry score 55, maintenance score 35, and adaptive confirmation from 3 to 10 seconds.
- Score range is `[-100, +100]` with EMA 35 points, Supertrend 40 points, and RSI 25 points.
- Startup, EA reload, runtime reinitialization, and reconnect establish a silent baseline and never replay historical alerts.
- Computer sound, optional native popup, large chart notification, and PushPlus execute only for a final confirmed reversal.
- Candidate signals remain local to the panel and are never sent to PushPlus.
- The EA monitors and alerts only; it must not import trading libraries or call order, position, or deal APIs.
- PushPlus Token remains a runtime input and must never appear in source, docs, tests, logs, panel text, URLs, provenance, or commits.
- Preserve the existing indicator MQ5/EX5 and keep the existing PushPlus App channel behavior.
- Accepted specification: `docs/superpowers/specs/2026-08-13-xauusd-m5-adaptive-score-design.md`.

---

### Task 1: Continuous Score Reference Model

**Files:**
- Create: `tests/adaptive_score_model.py`
- Create: `tests/test_adaptive_score.py`

**Interfaces:**
- Produces: `clamp_unit(value: float) -> float`, `ema_score(...) -> float`, `supertrend_score(...) -> float`, `rsi_score(...) -> float`, `composite_score(...) -> ScoreSnapshot`, and `required_seconds(...) -> float`.
- Produces immutable `ScoreSnapshot(ema, supertrend, rsi, total)`.
- Consumes no EA runtime state.

- [ ] **Step 1: Write failing formula and boundary tests**

Create `tests/test_adaptive_score.py` with table-driven tests equivalent to:

```python
class AdaptiveScoreTests(unittest.TestCase):
    def test_component_extremes_and_neutral_values(self):
        self.assertAlmostEqual(ema_score(101, 100, 101, 100, 1), 35)
        self.assertAlmostEqual(ema_score(99, 100, 99, 100, 1), -35)
        self.assertAlmostEqual(supertrend_score(101, 100, 1), 40)
        self.assertAlmostEqual(supertrend_score(99, 100, 1), -40)
        self.assertEqual(rsi_score(50), 0)
        self.assertEqual(rsi_score(52), 0)
        self.assertEqual(rsi_score(60), 25)
        self.assertEqual(rsi_score(40), -25)

    def test_composite_is_clamped_to_one_hundred(self):
        score = composite_score(
            fast=105, slow=100, previous_completed_fast=99,
            price=110, supertrend_line=100, atr=1, rsi=80
        )
        self.assertEqual(score.total, 100)

    def test_invalid_atr_is_rejected(self):
        for atr in (0.0, -1.0, math.nan, math.inf):
            with self.subTest(atr=atr):
                with self.assertRaises(ValueError):
                    composite_score(1, 1, 1, 1, 1, atr, 50)

    def test_confirmation_time_is_bounded_and_monotonic(self):
        values = [required_seconds(score) for score in (55, 60, 70, 80, 100)]
        self.assertEqual(values[0], 10)
        self.assertEqual(values[-1], 3)
        self.assertTrue(all(3 <= value <= 10 for value in values))
        self.assertEqual(values, sorted(values, reverse=True))
```

- [ ] **Step 2: Run the focused test and verify failure**

Run:

```powershell
python -m unittest tests.test_adaptive_score -v
```

Expected: FAIL because `tests/adaptive_score_model.py` does not exist.

- [ ] **Step 3: Implement the approved formulas**

Implement these exact defaults and formulas in `tests/adaptive_score_model.py`:

```python
EMA_DISTANCE_WEIGHT = 25.0
EMA_SLOPE_WEIGHT = 10.0
SUPERTREND_WEIGHT = 40.0
RSI_WEIGHT = 25.0

def ema_score(fast, slow, previous_completed_fast, atr):
    distance = 25.0 * clamp_unit((fast - slow) / (0.20 * atr))
    slope = 10.0 * clamp_unit(
        (fast - previous_completed_fast) / (0.08 * atr)
    )
    return distance + slope

def supertrend_score(price, line, atr):
    return 40.0 * clamp_unit((price - line) / (0.50 * atr))

def rsi_score(rsi):
    if 48.0 <= rsi <= 52.0:
        return 0.0
    if rsi > 52.0:
        return 25.0 * clamp_unit((rsi - 52.0) / 8.0)
    return 25.0 * clamp_unit((rsi - 48.0) / 8.0)

def required_seconds(score):
    return max(3.0, min(10.0, 10.0 - (abs(score) - 55.0) * 7.0 / 25.0))
```

Reject non-finite inputs and non-positive ATR before division. Clamp the final total to `[-100, 100]`.

- [ ] **Step 4: Run the focused and full suites**

Run:

```powershell
python -m unittest tests.test_adaptive_score -v
python -m unittest discover -s tests -p "test_*.py" -v
```

Expected: all new scoring tests PASS; existing tests remain PASS.

- [ ] **Step 5: Commit the reference scoring model**

```powershell
git add -- tests/adaptive_score_model.py tests/test_adaptive_score.py
git commit -m "test: define adaptive reversal scoring"
```

### Task 2: Adaptive Confirmation State Machine

**Files:**
- Modify: `tests/adaptive_score_model.py`
- Create: `tests/test_adaptive_confirmation.py`

**Interfaces:**
- Consumes: total score, effective tick delta, entry score 55, maintenance score 35, and confirmation range 3–10 seconds.
- Produces: immutable `ConfirmationState(confirmed, pending, progress, last_tick_ms)` and `advance_confirmation(...) -> tuple[ConfirmationState, bool]`.
- Direction values remain `-1`, `0`, and `+1`.

- [ ] **Step 1: Write failing state-transition tests**

Cover these exact cases:

```python
def test_first_direction_sets_silent_baseline(self):
    state, alerted = advance_confirmation(ConfirmationState(), 70, 1_000)
    self.assertEqual(state.confirmed, 1)
    self.assertFalse(alerted)

def test_strong_reversal_confirms_after_three_active_seconds(self):
    state = ConfirmationState(confirmed=1)
    for now in (1_000, 2_000, 3_000, 4_000):
        state, alerted = advance_confirmation(state, -80, now)
    self.assertTrue(alerted)
    self.assertEqual(state.confirmed, -1)

def test_maintenance_zone_rewinds_at_half_speed(self):
    state = ConfirmationState(
        confirmed=1, pending=-1, progress=0.60, last_tick_ms=1_000
    )
    state, alerted = advance_confirmation(state, -45, 2_000)
    self.assertAlmostEqual(state.progress, 0.55)
    self.assertFalse(alerted)

def test_neutral_rewinds_at_normal_speed(self):
    state = ConfirmationState(
        confirmed=1, pending=-1, progress=0.60, last_tick_ms=1_000
    )
    state, _ = advance_confirmation(state, 0, 2_000)
    self.assertAlmostEqual(state.progress, 0.50)

def test_explicit_opposite_evidence_clears_pending(self):
    state = ConfirmationState(
        confirmed=1, pending=-1, progress=0.60, last_tick_ms=1_000
    )
    state, _ = advance_confirmation(state, 40, 2_000)
    self.assertEqual(state.pending, 0)
    self.assertEqual(state.progress, 0)

def test_inactive_tick_gap_never_advances(self):
    state = ConfirmationState(confirmed=1)
    state, _ = advance_confirmation(state, -80, 1_000)
    state, alerted = advance_confirmation(state, -80, 5_000)
    self.assertEqual(state.progress, 0)
    self.assertFalse(alerted)
```

Also test boundary scores `-55`, `-35`, `35`, `55`, same-direction non-repetition, candidate replacement, progress clamping, and reconnect reset followed by silent baseline.

- [ ] **Step 2: Run the focused test and verify failure**

Run:

```powershell
python -m unittest tests.test_adaptive_confirmation -v
```

Expected: FAIL because `ConfirmationState` and `advance_confirmation` are undefined.

- [ ] **Step 3: Implement one transition function**

Implement `advance_confirmation` without wall-clock accumulation. Only deltas in `[0, max_active_gap_ms]` participate. Use:

- `delta / required_seconds(score)` for active candidate growth;
- `delta / max_confirmation_seconds × 0.5` for maintenance-zone rewind;
- `delta / max_confirmation_seconds` for neutral rewind;
- immediate reset for evidence at least 35 points in the opposite direction.

When progress reaches 1, set the confirmed direction, clear pending state, and return `alerted=True`. A score that supports the already confirmed direction cannot alert.

- [ ] **Step 4: Run focused and full tests**

Run:

```powershell
python -m unittest tests.test_adaptive_confirmation -v
python -m unittest discover -s tests -p "test_*.py" -v
```

Expected: all tests PASS.

- [ ] **Step 5: Commit the adaptive state model**

```powershell
git add -- tests/adaptive_score_model.py tests/test_adaptive_confirmation.py
git commit -m "test: define adaptive confirmation state"
```

### Task 3: Incremental Supertrend Model and Replay Fixture

**Files:**
- Modify: `tests/adaptive_score_model.py`
- Create: `tests/test_incremental_supertrend.py`
- Create: `tests/fixtures/xauusd_m5_adaptive_replay.csv`
- Create: `tools/compare_adaptive_replay.py`
- Create: `tests/test_adaptive_replay.py`

**Interfaces:**
- Produces: `Bar(time, open, high, low, close, atr)`, `SupertrendState(final_upper, final_lower, long_trend, previous_close, committed_time)`, `advance_supertrend(state, bar)`, and `preview_supertrend(state, current_bar)`.
- Produces replay report columns `segment`, `legacy_alert_time`, `adaptive_alert_time`, `adaptive_lead_seconds`, and `range_alert_count`.
- Consumes deterministic CSV columns `segment,time,open,high,low,close,atr,fast,slow,previous_fast,rsi`.

- [ ] **Step 1: Write failing incremental-equivalence tests**

Test that:

- sequential `advance_supertrend` equals a full replay over the same bars;
- repeated `preview_supertrend` calls leave the committed state unchanged;
- the next M5 commits the prior completed bar exactly once;
- duplicate or older bar times raise `ValueError`;
- reset plus replay produces the same state as fresh initialization.

Use multiplier `2.4` and numeric tolerance `1e-9`.

- [ ] **Step 2: Run the focused test and verify failure**

Run:

```powershell
python -m unittest tests.test_incremental_supertrend -v
```

Expected: FAIL because the Supertrend state API is not implemented.

- [ ] **Step 3: Implement the pure incremental reference**

Implement the same recurrence used by the EA:

```python
basic_upper = midpoint + multiplier * atr
basic_lower = midpoint - multiplier * atr
final_upper = (
    previous.final_upper
    if basic_upper >= previous.final_upper
    and previous_close <= previous.final_upper
    else basic_upper
)
final_lower = (
    previous.final_lower
    if basic_lower <= previous.final_lower
    and previous_close >= previous.final_lower
    else basic_lower
)
```

Flip long trend below `final_lower` and short trend above `final_upper`. `preview_supertrend` returns a new temporary state and line without mutating the committed state.

- [ ] **Step 4: Add the fixed deterministic replay fixture**

Create `tests/fixtures/xauusd_m5_adaptive_replay.csv` with at least 120 five-minute rows divided into:

- 30-row rising trend;
- 20-row top and bearish reversal;
- 30-row falling trend;
- 20-row V reversal;
- 20-row alternating range.

Generate values once with a deterministic formula and commit the resulting CSV. Use fixed ATR, EMA, and RSI columns so replay results never depend on a broker feed or the current date. Do not generate fixture values during tests.

- [ ] **Step 5: Implement old-versus-new replay comparison**

In `tools/compare_adaptive_replay.py`, implement:

- legacy EMA/Supertrend/RSI two-of-three vote plus 10-second hold;
- new continuous score plus adaptive confirmation;
- deterministic expansion of each M5 snapshot into 1-second active ticks for the first 10 seconds of that bar, holding the fixture's indicator snapshot constant during those ticks;
- CSV report output to stdout;
- nonzero exit if adaptive is not earlier in a majority of fixture-marked clear reversals, range alerts exceed `legacy × 1.5`, or duplicate same-direction alerts occur.

In `tests/test_adaptive_replay.py`, load the same fixture and assert those acceptance conditions directly.

- [ ] **Step 6: Run replay and all tests**

Run:

```powershell
python tools/compare_adaptive_replay.py tests/fixtures/xauusd_m5_adaptive_replay.csv
python -m unittest tests.test_incremental_supertrend tests.test_adaptive_replay -v
python -m unittest discover -s tests -p "test_*.py" -v
```

Expected: comparison exits 0; incremental, replay, and full suites PASS.

- [ ] **Step 7: Commit incremental and replay verification**

```powershell
git add -- tests/adaptive_score_model.py tests/test_incremental_supertrend.py tests/test_adaptive_replay.py tests/fixtures/xauusd_m5_adaptive_replay.csv tools/compare_adaptive_replay.py
git commit -m "test: add adaptive replay comparison"
```

### Task 4: Implement Adaptive Scoring and Incremental Runtime in MQL5

**Files:**
- Modify: `MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5`
- Modify: `tests/test_pushplus_ea_contract.py`
- Modify: `tests/test_signal_logic.py`

**Interfaces:**
- Produces MQL functions:
  - `double ClampUnit(const double value)`
  - `bool InitializeSupertrendCache()`
  - `bool PreviewCurrentSupertrend(const MqlRates &bar,const double atr,double &line)`
  - `bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)`
  - `double RequiredConfirmationSeconds(const double score)`
  - `bool AdvanceAdaptiveState(const double score,const ulong now_ms)`
- Replaces `SignalSnapshot` vote fields with score fields: `ema_score`, `supertrend_score`, `rsi_score`, `total_score`, `required_seconds`.
- Consumes the existing timer lifecycle, symbol resolution, PushPlus transport, large notification, and warning ownership.

- [ ] **Step 1: Add failing MQL source-contract tests**

Update `tests/test_pushplus_ea_contract.py` to require:

```python
for text in (
    "input int InpFastEmaPeriod = 7;",
    "input int InpSlowEmaPeriod = 18;",
    "input int InpAtrPeriod = 8;",
    "input double InpSupertrendMultiplier = 2.4;",
    "input int InpRsiPeriod = 9;",
    "InpRsiNeutralLower = 48.0",
    "InpRsiNeutralUpper = 52.0",
    "InpCandidateEntryScore = 55.0",
    "InpDirectionMaintenanceScore = 35.0",
    "InpMinimumConfirmationSeconds = 3.0",
    "InpMaximumConfirmationSeconds = 10.0",
    "double ClampUnit(",
    "bool InitializeSupertrendCache(",
    "bool PreviewCurrentSupertrend(",
    "bool ReadAdaptiveSignal(",
    "double RequiredConfirmationSeconds(",
    "bool AdvanceAdaptiveState(",
):
    self.assertIn(text, self.source)
```

Require the literal normalization scales `0.20`, `0.08`, `0.50`, weights `25.0`, `10.0`, `40.0`, `25.0`, and finite-value checks. Assert `ReadAdaptiveSignal` does not call `CopyRates(..., count, ...)` or loop across `RequiredHistoryBars()` on every tick.

Retire legacy majority-vote behavior tests from `tests/test_signal_logic.py`; keep only symbol-independent tests that still describe current behavior, or move them to the new adaptive test modules.

- [ ] **Step 2: Run contract tests and verify failure**

Run:

```powershell
python -m unittest tests.test_pushplus_ea_contract -v
```

Expected: FAIL on missing adaptive inputs and functions.

- [ ] **Step 3: Add validated inputs and score data types**

Replace the old hold input with entry/maintenance thresholds and minimum/maximum confirmation seconds. Add advanced weight and normalization inputs using the approved defaults. Validate:

- periods in `[1, 500]` and fast period below slow period;
- weights positive and totaling 100 within `1e-6`;
- RSI lower `< 50 <` upper within `[0, 100]`;
- `0 < maintenance < entry <= 100`;
- `0 < minimum <= maximum`;
- normalization scales positive and finite.

On invalid input, retain the EA and render the exact parameter class that failed; do not produce a signal.

- [ ] **Step 4: Implement cached Supertrend initialization and preview**

At initialization, copy bounded completed M5 history once and sequentially populate cached final bands, trend, previous close, and committed open time. During the active M5:

- preview with cached completed state and current bar;
- do not mutate completed cache;
- when a later M5 open time appears, commit the prior completed bar once;
- rebuild silently when time moves backward, history changes, or reconnect reset fires.

Keep history multiplication overflow-safe and capped by `MAX_HISTORY_BARS`.

- [ ] **Step 5: Implement score acquisition**

Read current and previous completed fast EMA, current slow EMA, ATR, RSI, current price, and preview Supertrend line. Calculate the exact approved three component scores, reject invalid/non-finite data, clamp total to `[-100, 100]`, and store all components in `ScoreSnapshot`.

- [ ] **Step 6: Implement adaptive confirmation**

Replace `AdvanceReversalState` with `AdvanceAdaptiveState`. Preserve:

- silent initial baseline;
- active-tick-only time accounting;
- 3–10 second strength-dependent progress;
- half-speed maintenance rewind;
- normal neutral rewind;
- immediate candidate reset on explicit opposite evidence;
- one notification per confirmed transition;
- silent reconnect baseline.

Use floating-point progress rather than integer elapsed hold time.

- [ ] **Step 7: Run all automated checks**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
python tools/compare_adaptive_replay.py tests/fixtures/xauusd_m5_adaptive_replay.csv
rg -n "OrderSend|CTrade|PositionOpen|PositionClose|trade\\.Buy|trade\\.Sell|HistoryDeal" MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5
rg -n "Print.*InpPushPlusToken|Alert.*InpPushPlusToken|InpPushPlusUrl.*InpPushPlusToken" MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5
git diff --check
```

Expected: tests and replay PASS; forbidden searches return no matches; diff check is clean.

- [ ] **Step 8: Commit the MQL algorithm**

```powershell
git add -- MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5 tests/test_pushplus_ea_contract.py tests/test_signal_logic.py
git commit -m "feat: add adaptive reversal scoring"
```

### Task 5: Update Panel, Notifications, Messages, and Documentation

**Files:**
- Modify: `MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5`
- Modify: `tests/test_pushplus_ea_contract.py`
- Modify: `README.md`

**Interfaces:**
- Consumes `ScoreSnapshot` and adaptive confirmation state.
- Produces panel text for total score, three components, confirmed direction, candidate direction, target confirmation seconds, progress percentage, and remaining seconds.
- Produces confirmed alert content containing the final score and components.

- [ ] **Step 1: Add failing presentation contract tests**

Require the panel and final message source to include:

```python
for text in (
    "综合评分：",
    "EMA贡献：",
    "Supertrend贡献：",
    "RSI贡献：",
    "候选方向：",
    "确认进度：",
    "目标确认：",
    "最终评分：",
):
    self.assertIn(text, self.source)
```

Assert `EmitConfirmedReversal` remains the only call site for `SendPushPlus` associated with market direction and that candidate-state rendering never calls it.

- [ ] **Step 2: Run presentation contract and verify failure**

Run:

```powershell
python -m unittest tests.test_pushplus_ea_contract -v
```

Expected: FAIL on missing score presentation strings.

- [ ] **Step 3: Update panel rendering**

Render signed scores with one decimal place. Show `偏多`, `偏空`, or `中性` from the maintenance threshold. While pending, show target confirmation seconds, integer progress percent, and nonnegative estimated remaining seconds. When no candidate exists, show `候选方向：无`.

- [ ] **Step 4: Update final notification content**

Replace legacy discrete vote lines with final total and three contributions in:

- PushPlus body;
- large centered notification;
- optional native MT5 Alert text.

Preserve sound and PushPlus error independence. Preserve persistent PushPlus warning behavior. Do not send any candidate message.

- [ ] **Step 5: Update Chinese operator documentation**

In `README.md`, document:

- new balanced default parameters;
- score interpretation and 55/35 hysteresis;
- adaptive 3–10 second confirmation;
- candidate information is panel-only;
- only confirmed reversals reach the phone;
- historical comparison is not a profit promise;
- reinstall/reload steps for replacing the EX5.

- [ ] **Step 6: Run tests and documentation checks**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
rg -n "连续评分|EMA 7|EMA 18|Supertrend|RSI 9|55|35|3.*10|只.*确认|不.*交易" README.md
git diff --check
```

Expected: full suite PASS; all required documentation concepts are present; diff is clean.

- [ ] **Step 7: Commit presentation and docs**

```powershell
git add -- MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5 tests/test_pushplus_ea_contract.py README.md
git commit -m "feat: display adaptive signal progress"
```

### Task 6: Compile, Independently Verify, Deliver, and Push

**Files:**
- Modify: `MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.ex5`
- Modify: `verification/pushplus-ea-build-provenance.txt`

**Interfaces:**
- Produces a MetaEditor-compiled EX5 matching the committed MQ5.
- Produces updated compiler result, replay result, test count, and exact MQ5/EX5 SHA-256.
- Produces a matching local delivery copy without exposing the PushPlus Token.

- [ ] **Step 1: Compile the actual EA**

Run MetaEditor 5 with an explicit compile log:

```powershell
$metaEditor = 'C:\Program Files\MetaTrader 5\MetaEditor64.exe'
$source = Join-Path $PWD 'MQL5\Experts\XAUUSD_M5_Reversal_Alert_EA.mq5'
$compileLog = Join-Path $env:TEMP 'xauusd-adaptive-metaeditor.log'
& $metaEditor /compile:$source /log:$compileLog
Get-Content -Raw -LiteralPath $compileLog
```

Expected: compile output contains `0 errors, 0 warnings`, and the EX5 modification time updates.

- [ ] **Step 2: Run fresh full verification**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
python tools/compare_adaptive_replay.py tests/fixtures/xauusd_m5_adaptive_replay.csv
git diff --check
rg -n "TBD|TODO|FIXME" MQL5/Experts tests tools README.md verification
rg -n "OrderSend|CTrade|PositionOpen|PositionClose|trade\\.Buy|trade\\.Sell|HistoryDeal" MQL5/Experts
rg -n '(?i)InpPushPlusToken\s*=\s*"[0-9a-f]{16,}"|token["=: ]+[0-9a-f]{16,}' MQL5 README.md tests tools docs verification
```

Expected: tests and replay PASS; diff check is clean; no placeholders, trading APIs, or previously exposed Token are found.

- [ ] **Step 3: Perform implementation review**

Review the MQ5 against every section of the approved spec, concentrating on:

- exact formula signs and normalization;
- preview state not mutating committed Supertrend;
- no full-history work per tick;
- threshold boundary behavior;
- active-tick time and rewind arithmetic;
- startup/reconnect silence;
- confirmed-only one-shot alerts;
- warning ownership and secret redaction;
- object cleanup and large notification sizing.

Fix every Critical or Important finding, then repeat Steps 1 and 2.

- [ ] **Step 4: Refresh provenance and verify hashes**

Update `verification/pushplus-ea-build-provenance.txt` with:

- build date;
- MetaEditor version;
- `0 errors, 0 warnings`;
- full test count and pass result;
- replay acceptance result;
- MQ5 SHA-256;
- EX5 SHA-256;
- statement that no Token is stored.

Run `Get-FileHash -Algorithm SHA256` on both files and compare them character-for-character with the record.

- [ ] **Step 5: Commit verified artifacts**

```powershell
git add -- MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5 MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.ex5 README.md tests tools verification/pushplus-ea-build-provenance.txt
git commit -m "chore: verify adaptive reversal EA"
```

- [ ] **Step 6: Copy the verified EX5 to the local delivery path**

Copy the EX5 to:

`C:\Users\Administrator\Desktop\XAUUSD_M5_Reversal_Alert_EA.ex5`

Compare the desktop SHA-256 with the repository EX5. If the desktop path requires approval, request it explicitly. Do not alter the existing indicator EX5.

- [ ] **Step 7: Push the current branch**

Run:

```powershell
git status --short
git push origin codex/xauusd-pushplus-ea
```

Expected: clean worktree and successful update of the existing draft PR branch.

- [ ] **Step 8: Handoff runtime verification**

Tell the user to reload the new EA, preserve their runtime PushPlus Token input, and observe:

- clear reversals normally confirm sooner than the legacy version;
- candidate score and progress appear only on the computer panel;
- phone and large notification occur only after final confirmation;
- no trade is opened.

Do not send an external PushPlus test unless the user separately asks for one in that turn.
