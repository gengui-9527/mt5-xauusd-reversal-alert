# XAUUSD M5 Reversal Alert Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a MetaTrader 5 custom indicator that monitors XAUUSD M5 intrabar data and alerts once when a three-factor majority reversal remains valid for 10 seconds.

**Architecture:** Keep the deployable indicator in one `.mq5` file because MetaTrader installation is simplest that way, but separate its internals into symbol resolution, indicator data, Supertrend calculation, voting, reversal state machine, alerting, and panel rendering functions. Use a deterministic Python reference test to exercise voting and timing transitions independently of MT5, then compile with MetaEditor when available.

**Tech Stack:** MQL5 custom indicator API, MT5 EMA/ATR/RSI handles, millisecond timer, chart labels, Python 3 reference tests.

## Global Constraints

- The indicator monitors the configured XAUUSD-family symbol at `PERIOD_M5`, regardless of the chart timeframe.
- Signals use the live, unclosed M5 bar and update only after a new target-symbol tick.
- Defaults are EMA 9/21, Supertrend ATR 10 × 3.0, RSI 14 with midpoint 50, and a 10-second hold.
- A direction requires at least two of three votes; exact equality produces no vote for that factor.
- Initial baseline, reload, and reconnection never emit a historical or startup alert.
- No-tick time does not advance confirmation.
- The indicator alerts only; it never places or modifies orders.
- The accepted design is `docs/superpowers/specs/2026-08-12-xauusd-m5-reversal-alert-design.md`.

---

### Task 1: Deterministic Voting and Reversal-State Reference Tests

**Files:**
- Create: `tests/test_signal_logic.py`

**Interfaces:**
- Produces: Python reference functions `majority_vote(ema_vote, supertrend_vote, rsi_vote) -> int` and `advance(state, candidate, tick_ms, hold_ms, max_tick_gap_ms) -> tuple[State, bool]`.
- State direction values are `-1` for short, `0` for neutral/uninitialized, and `1` for long.

- [ ] **Step 1: Write voting tests**

```python
import unittest
from dataclasses import dataclass


class SignalLogicTests(unittest.TestCase):
    def test_majority_vote_all_combinations(self):
        self.assertEqual(majority_vote(1, 1, -1), 1)
        self.assertEqual(majority_vote(1, -1, -1), -1)
        self.assertEqual(majority_vote(1, -1, 0), 0)
        self.assertEqual(majority_vote(0, 1, 1), 1)
        self.assertEqual(majority_vote(0, -1, -1), -1)
```

- [ ] **Step 2: Run the test and verify the reference functions are missing**

Run: `python -m unittest discover -s tests -p "test_*.py" -v`

Expected: FAIL because `majority_vote` is not defined.

- [ ] **Step 3: Add the minimal voting reference**

```python
def majority_vote(*votes: int) -> int:
    longs = sum(v == 1 for v in votes)
    shorts = sum(v == -1 for v in votes)
    if longs >= 2:
        return 1
    if shorts >= 2:
        return -1
    return 0
```

- [ ] **Step 4: Add state-machine tests**

```python
@dataclass(frozen=True)
class State:
    confirmed: int = 0
    pending: int = 0
    pending_elapsed_ms: int = 0
    last_tick_ms: int = 0


class ReversalStateTests(unittest.TestCase):
    def test_initial_direction_sets_baseline_without_alert(self):
        state, alert = advance(State(), 1, 1_000, 10_000, 1_000)
        self.assertEqual(state.confirmed, 1)
        self.assertFalse(alert)

    def test_reversal_requires_full_continuous_active_ticks_and_alerts_once(self):
        state = State(confirmed=1)
        for tick_ms in range(1_000, 11_001, 1_000):
            state, alert = advance(state, -1, tick_ms, 10_000, 1_000)
        self.assertTrue(alert)
        self.assertEqual(state.confirmed, -1)
        state, alert = advance(state, -1, 12_000, 10_000, 1_000)
        self.assertFalse(alert)

    def test_neutral_resets_pending_timer(self):
        state = State(confirmed=1)
        state, _ = advance(state, -1, 1_000, 10_000, 1_000)
        state, _ = advance(state, 0, 2_000, 10_000, 1_000)
        self.assertEqual(state.pending, 0)

    def test_no_tick_gap_does_not_advance_confirmation(self):
        state = State(confirmed=1)
        state, _ = advance(state, -1, 1_000, 10_000, 1_000)
        state, alert = advance(state, -1, 20_000, 10_000, 1_000)
        self.assertFalse(alert)
        self.assertEqual(state.pending_elapsed_ms, 0)
```

- [ ] **Step 5: Implement `advance` and run the complete tests**

```python
def advance(
    state: State,
    candidate: int,
    tick_ms: int,
    hold_ms: int,
    max_tick_gap_ms: int,
):
    if state.confirmed == 0:
        return (
            State(confirmed=candidate) if candidate else state,
            False,
        )
    if candidate == 0 or candidate == state.confirmed:
        return State(confirmed=state.confirmed), False
    if state.pending != candidate:
        return State(state.confirmed, candidate, 0, tick_ms), False
    delta = tick_ms - state.last_tick_ms
    elapsed = state.pending_elapsed_ms
    if 0 <= delta <= max_tick_gap_ms:
        elapsed += delta
    if elapsed < hold_ms:
        return State(state.confirmed, candidate, elapsed, tick_ms), False
    return State(confirmed=candidate), True


if __name__ == "__main__":
    unittest.main()
```

Run: `python -m unittest discover -s tests -p "test_*.py" -v`

Expected: all tests PASS.

- [ ] **Step 6: Commit**

```powershell
git add -- tests/test_signal_logic.py
git commit -m "test: define reversal alert state behavior"
```

### Task 2: Indicator Initialization, Symbol Resolution, and Input Validation

**Files:**
- Create: `MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5`

**Interfaces:**
- Produces: `bool ResolveTargetSymbol()`, `bool ValidateInputs()`, `bool CreateIndicatorHandles()`, `void ReleaseResources()`.
- Produces global handles `g_fast_ema_handle`, `g_slow_ema_handle`, `g_atr_handle`, and `g_rsi_handle`.
- Later tasks consume `g_symbol`, validated input values, and initialized handles.

- [ ] **Step 1: Add indicator metadata, inputs, state constants, and lifecycle skeleton**

Define `#property indicator_chart_window`, zero plot buffers, enums for direction/status, all accepted design inputs, `OnInit`, `OnDeinit`, `OnCalculate`, and `OnTimer`. `OnCalculate` must return `rates_total`; target monitoring belongs in `OnTimer`.

- [ ] **Step 2: Implement exact and suffix-aware symbol resolution**

`ResolveTargetSymbol()` must first call `SymbolSelect(InpSymbol, true)`. If that fails, iterate `SymbolsTotal(false)`, select the first symbol for which `StringFind(candidate, InpSymbol) >= 0`, and store it in `g_symbol`. On failure, set a readable panel error and return `false`.

- [ ] **Step 3: Implement strict parameter validation**

Reject:

```text
Fast EMA <= 0
Slow EMA <= Fast EMA
ATR period <= 0
Supertrend multiplier <= 0
RSI period <= 0
RSI midpoint <= 0 or >= 100
Hold seconds <= 0
Timer milliseconds < 50
```

Return `INIT_PARAMETERS_INCORRECT` from `OnInit` when validation fails.

- [ ] **Step 4: Create M5 handles and timer**

Create `iMA` handles for EMA 9/21, `iATR`, and `iRSI`, all using `g_symbol` and `PERIOD_M5`. Treat any `INVALID_HANDLE` as initialization failure. Call `EventSetMillisecondTimer(InpTimerMilliseconds)` only after successful handle creation.

- [ ] **Step 5: Release all handles, timer, and panel objects**

`OnDeinit` calls `EventKillTimer()`, releases every non-invalid handle using `IndicatorRelease`, and removes only objects whose names use the indicator's unique prefix.

- [ ] **Step 6: Run structural checks**

Run:

```powershell
rg -n "OnInit|OnDeinit|OnCalculate|OnTimer|ResolveTargetSymbol|ValidateInputs|CreateIndicatorHandles|EventSetMillisecondTimer|IndicatorRelease" MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5
```

Expected: every lifecycle and resource-management symbol is present.

- [ ] **Step 7: Commit**

```powershell
git add -- MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5
git commit -m "feat: initialize XAUUSD M5 alert indicator"
```

### Task 3: Live Factor Calculation and Majority Vote

**Files:**
- Modify: `MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5`

**Interfaces:**
- Consumes: `g_symbol` and indicator handles from Task 2.
- Produces: `bool ReadLiveSignal(SignalSnapshot &snapshot)`, `int CalculateSupertrendVote(...)`, and `int MajorityVote(int ema_vote, int supertrend_vote, int rsi_vote)`.
- `SignalSnapshot` contains three factor votes, majority candidate, indicator values, target tick time, and server time.

- [ ] **Step 1: Define `SignalSnapshot` and exact vote semantics**

Use `DIR_LONG = 1`, `DIR_NONE = 0`, and `DIR_SHORT = -1`. EMA equality, RSI equality, and price equality with the Supertrend line each return `DIR_NONE`.

- [ ] **Step 2: Copy live M5 inputs safely**

`ReadLiveSignal` checks `BarsCalculated` for all handles, copies current EMA/RSI values at shift 0, copies at least 100 M5 `MqlRates` bars plus ATR values, and returns `false` without changing state if any requested copy count is incomplete.

- [ ] **Step 3: Calculate Supertrend in chronological order**

Normalize copied arrays to a documented oldest-to-newest order. For each bar compute:

```text
basic upper = (high + low) / 2 + multiplier × ATR
basic lower = (high + low) / 2 - multiplier × ATR
final upper = basic upper unless previous close <= previous final upper,
              otherwise min(basic upper, previous final upper)
final lower = basic lower unless previous close >= previous final lower,
              otherwise max(basic lower, previous final lower)
```

Carry the prior trend until close crosses the opposite final band, then expose the current line and vote.

- [ ] **Step 4: Implement factor votes and 2-of-3 majority**

EMA compares current fast and slow values. RSI compares to `InpRsiMidpoint`. `MajorityVote` exactly mirrors the Python reference from Task 1.

- [ ] **Step 5: Deduplicate target ticks**

Use `SymbolInfoTick(g_symbol, tick)` and compare both `tick.time_msc` and bid/ask against the last processed tick. `OnTimer` must return before calculation when the target tick is unchanged.

- [ ] **Step 6: Run reference and source checks**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
rg -n "ReadLiveSignal|CalculateSupertrendVote|MajorityVote|PERIOD_M5|time_msc" MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5
```

Expected: Python tests PASS and all required MQL5 functions/fields are present.

- [ ] **Step 7: Commit**

```powershell
git add -- MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5
git commit -m "feat: calculate live XAUUSD reversal votes"
```

### Task 4: Tick-Driven Ten-Second State Machine and Alerts

**Files:**
- Modify: `MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5`
- Modify: `tests/test_signal_logic.py`

**Interfaces:**
- Consumes: `SignalSnapshot.candidate`, tick deduplication, and server time from Task 3.
- Produces: `bool AdvanceReversalState(int candidate, ulong now_ms)`, `void EmitReversalAlert(int direction, datetime server_time)`.

- [ ] **Step 1: Add reconnection/no-tick behavior tests to the reference**

Add tests proving a tick gap greater than `InpMaximumActiveTickGapMs = 1000` contributes zero milliseconds to the hold duration, and that resetting to an uninitialized state establishes a baseline without alerting.

- [ ] **Step 2: Mirror the tested state machine in MQL5**

Keep `g_confirmed_direction`, `g_pending_direction`, `g_pending_elapsed_ms`, and `g_last_pending_tick_ms`. Use `GetTickCount64()` only when a new target tick is received. Add elapsed time only when the interval since the prior processed target tick is at most `InpMaximumActiveTickGapMs = 1000`; a longer no-quote gap contributes zero time, so confirmation pauses. Clear pending state on neutral or original-direction candidates. Return `true` exactly once when accumulated active-tick time reaches `InpHoldSeconds * 1000`.

- [ ] **Step 3: Detect reconnection before state evaluation**

Track the previous target tick server timestamp. If the gap exceeds a conservative reset threshold of 60 seconds, clear confirmed and pending directions so the first recovered valid candidate becomes the new silent baseline. Document the threshold as an input `InpReconnectResetSeconds = 60`.

- [ ] **Step 4: Emit direction-specific alerts**

When state advancement confirms a reversal:

```mql5
if(InpEnableSound)
   PlaySound(direction == DIR_LONG ? InpLongSound : InpShortSound);
if(InpEnablePopup)
   Alert(g_symbol, " M5 ", DirectionText(direction),
         " @ ", TimeToString(server_time, TIME_DATE|TIME_SECONDS));
```

Never call order-trading APIs.

- [ ] **Step 5: Run tests and search for accidental trading code**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
rg -n "AdvanceReversalState|EmitReversalAlert|PlaySound|Alert|GetTickCount64" MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5
rg -n "OrderSend|CTrade|PositionOpen|trade\\.Buy|trade\\.Sell" MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5
```

Expected: tests PASS; the first search finds alert/state functions; the trading-API search returns no matches.

- [ ] **Step 6: Commit**

```powershell
git add -- tests/test_signal_logic.py MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5
git commit -m "feat: confirm and alert on sustained reversals"
```

### Task 5: Status Panel and Operator Documentation

**Files:**
- Modify: `MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5`
- Create: `README.md`

**Interfaces:**
- Consumes: signal snapshot, confirmed/pending state, error text, and hold duration.
- Produces: `void RenderPanel(const SignalSnapshot *snapshot)` and complete installation/verification instructions.

- [ ] **Step 1: Implement a namespaced chart-label panel**

Create/update labels prefixed with `XAU_M5_RA_` showing actual symbol and M5, confirmed direction, all three votes, pending direction, elapsed/remaining seconds, and current error. Use input corner, offsets, and colors. Do not call `ObjectsDeleteAll` without a prefix.

- [ ] **Step 2: Render every runtime state**

Render initialization, symbol-not-found, insufficient-data, active, candidate countdown, confirmed direction, reconnect baseline, and sound-failure text. When no snapshot is available, the panel still shows the monitor symbol and error status.

- [ ] **Step 3: Write Chinese installation and parameter instructions**

The README must instruct the user to:

1. Open MT5 → File → Open Data Folder.
2. Copy the `.mq5` file into `MQL5/Indicators`.
3. Open MetaEditor and compile with zero errors.
4. Refresh Navigator and attach the indicator to any chart.
5. Ensure the target XAUUSD-family symbol is visible in Market Watch and Algo Trading permissions are not required because no orders are sent.
6. Test sounds from the MT5 `Sounds` directory and verify popup content.

Also document the three-factor rule, 10-second debounce, startup/reconnect behavior, parameter defaults, broker suffix matching, limitations, and lack of profitability guarantee.

- [ ] **Step 4: Run documentation and source completeness checks**

Run:

```powershell
rg -n "EMA|Supertrend|RSI|10 秒|安装|编译|XAUUSD|不.*下单" README.md
rg -n "RenderPanel|XAU_M5_RA_|ObjectCreate|ObjectSet" MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5
```

Expected: all accepted user-facing behaviors are documented and panel functions are present.

- [ ] **Step 5: Commit**

```powershell
git add -- README.md MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5
git commit -m "docs: add MT5 alert setup and status panel"
```

### Task 6: Compile and Final Verification

**Files:**
- Modify if required: `MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5`
- Modify if required: `README.md`

**Interfaces:**
- Consumes: all implementation artifacts.
- Produces: zero-error MetaEditor compilation when the compiler exists, or an explicit uncompiled handoff with exact user-side commands.

- [ ] **Step 1: Discover a local MetaEditor compiler**

Run:

```powershell
$candidates = @(
  "$env:ProgramFiles\MetaTrader 5\metaeditor64.exe",
  "${env:ProgramFiles(x86)}\MetaTrader 5\metaeditor64.exe"
)
$candidates | Where-Object { Test-Path -LiteralPath $_ }
```

Also search common terminal install directories by exact filename if these paths are absent.

- [ ] **Step 2: Compile when MetaEditor exists**

Run:

```powershell
& $metaEditorPath /compile:"$PWD\MQL5\Indicators\XAUUSD_M5_Reversal_Alert.mq5" /log:"$PWD\metaeditor-compile.log"
Get-Content -Raw -LiteralPath "$PWD\metaeditor-compile.log"
```

Expected: `0 error(s), 0 warning(s)`. Fix any compiler errors and rerun until this exact result is reached.

- [ ] **Step 3: Run all non-terminal checks**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
git diff --check
rg -n "TBD|TODO|FIXME" MQL5 README.md tests
rg -n "OrderSend|CTrade|PositionOpen|trade\\.Buy|trade\\.Sell" MQL5
```

Expected: all tests PASS, no whitespace errors, no placeholders, and no trading APIs.

- [ ] **Step 4: Record the verification boundary**

If MetaEditor is unavailable, add a README note stating that local compilation was not performed and preserve the exact compile steps. Do not claim compile success. If it is available, record the compiler result and location of the generated `.ex5`.

- [ ] **Step 5: Review the final diff against every design section**

Confirm signal defaults, intrabar behavior, tick-only timing, startup/reconnect baseline, one-shot direction-specific alerts, panel states, cleanup, suffix matching, and documentation are all present.

- [ ] **Step 6: Commit final verification fixes**

```powershell
git add -- MQL5/Indicators/XAUUSD_M5_Reversal_Alert.mq5 README.md tests/test_signal_logic.py
git commit -m "chore: verify XAUUSD M5 reversal indicator"
```
