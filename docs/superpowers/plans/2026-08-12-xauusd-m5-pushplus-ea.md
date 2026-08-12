# XAUUSD M5 PushPlus Alert EA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deliver a non-trading MT5 EA that reproduces the approved XAUUSD M5 reversal signal and sends one audible PushPlus App notification per confirmed reversal.

**Architecture:** Adapt the verified indicator signal/state implementation into an EA event lifecycle, then add a separate PushPlus transport boundary using synchronous `WebRequest()` from the EA timer thread. Keep secrets exclusively in runtime inputs, validate message construction with Python contract tests, compile with MetaEditor, and preserve the existing indicator.

**Tech Stack:** MQL5 EA API, `WebRequest`, PushPlus HTTPS JSON API, Python `unittest`, MetaEditor 5.

## Global Constraints

- Monitor the configured XAUUSD-family symbol on live `PERIOD_M5` data regardless of the attached chart.
- Use EMA 9/21, Supertrend ATR 10 × 3.0, RSI 14/50, two-of-three voting, and 10 seconds of active-tick confirmation by default.
- Startup and reconnect establish a silent baseline.
- Send PushPlus only for confirmed reversals, never for runtime status changes.
- PushPlus defaults: `https://www.pushplus.plus/send`, `app`, `txt`, 5000 ms.
- The default runtime path sends only to the PushPlus App channel and does not send to the `wechat` channel.
- The Token defaults to empty and must never appear in source, docs, logs, panel text, committed fixtures, or URLs.
- No trading libraries or order APIs.
- Preserve the existing indicator source and EX5.
- Accepted specification: `docs/superpowers/specs/2026-08-12-xauusd-m5-pushplus-ea-design.md`.

---

### Task 1: PushPlus Message and Security Contract Tests

**Files:**
- Create: `tests/test_pushplus_ea_contract.py`

**Interfaces:**
- Produces source-contract assertions for `JsonEscape`, `BuildReversalTitle`, `BuildReversalContent`, `SendPushPlus`, token redaction, and forbidden trading APIs.

- [ ] **Step 1: Write failing source contract tests**

Create tests that require:

```python
self.assertIn("string JsonEscape(", source)
self.assertIn("string BuildReversalTitle(", source)
self.assertIn("string BuildReversalContent(", source)
self.assertIn("bool SendPushPlus(", source)
self.assertIn("WebRequest(", source)
self.assertIn('input string InpPushPlusToken = "";', source)
self.assertNotIn("OrderSend", source)
self.assertNotIn("CTrade", source)
```

Also assert the source includes escapes for `\\`, `"`, newline, carriage return, and tab; POST JSON fields `token`, `title`, `content`, `template`, `channel`; and does not concatenate the Token into `Print`, panel text, or the URL.

- [ ] **Step 2: Run and observe the expected missing-file failure**

Run: `python -m unittest discover -s tests -p "test_*.py" -v`

Expected: FAIL because the EA source does not exist.

- [ ] **Step 3: Commit the failing contract**

```powershell
git add -- tests/test_pushplus_ea_contract.py
git commit -m "test: define PushPlus EA security contract"
```

### Task 2: Build the Non-Trading EA Signal Runtime

**Files:**
- Create: `MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5`
- Modify: `tests/test_pushplus_ea_contract.py`

**Interfaces:**
- Produces EA lifecycle `OnInit`, `OnDeinit`, `OnTimer`; signal functions `ReadLiveSignal`, `CalculateSupertrendVote`, `MajorityVote`; state function `AdvanceReversalState`.
- Consumes behavior already covered by `tests/test_signal_logic.py`.

- [ ] **Step 1: Add failing lifecycle and signal source assertions**

Require the EA source to contain `#property strict`, timer lifecycle, M5 handles, suffix-aware symbol resolution, dynamic bounded ATR history, tick deduplication, reconnect reset, unique panel prefix, and no `OnCalculate`.

- [ ] **Step 2: Implement the minimal EA runtime**

Adapt the compiled indicator implementation into `MQL5/Experts`, removing indicator-only properties and `OnCalculate`. Preserve validated period limits, retryable initialization, active-tick state accumulation, sound/popup alerts, persistent warnings, and panel cleanup.

- [ ] **Step 3: Run all tests**

Run: `python -m unittest discover -s tests -p "test_*.py" -v`

Expected: all legacy signal tests and new EA source contracts PASS.

- [ ] **Step 4: Commit**

```powershell
git add -- MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5 tests/test_pushplus_ea_contract.py
git commit -m "feat: add non-trading XAUUSD alert EA"
```

### Task 3: Add PushPlus Transport and Message Semantics

**Files:**
- Modify: `MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5`
- Modify: `tests/test_pushplus_ea_contract.py`

**Interfaces:**
- Produces `string JsonEscape(string value)`, `string BuildReversalTitle(int previous_direction, int direction)`, `string BuildReversalContent(...)`, `bool SendPushPlus(string title, string content)`, and `void EmitConfirmedReversal(...)`.

- [ ] **Step 1: Add failing message semantics assertions**

Require explicit strings for `空转多`, `多转空`, all message fields, `application/json; charset=utf-8`, UTF-8 conversion, HTTP 200 handling, business-code parsing, and a startup-test guard.

- [ ] **Step 2: Implement JSON construction**

Escape all JSON control characters, construct a POST body with token/title/content/template/channel, and convert using `StringToCharArray(..., CP_UTF8)` while excluding the terminal null byte.

- [ ] **Step 3: Implement safe response handling**

Return failure without network access when PushPlus is disabled or Token is empty. Call `WebRequest("POST", ...)`, classify `-1`, non-200, missing code, and non-success business code without logging the Token or request body. Record only sanitized status text.

- [ ] **Step 4: Wire one request to each confirmed reversal**

Capture the previous confirmed direction before state advancement. After confirmation, build the correct transition title/body and call sound, popup, and PushPlus exactly once. Startup test remains independent and executes at most once per EA instance when enabled.

- [ ] **Step 5: Run tests and scan for secret leakage/trading APIs**

Run:

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
rg -n "OrderSend|CTrade|PositionOpen|trade\\.Buy|trade\\.Sell" MQL5/Experts
rg -n "Print.*InpPushPlusToken|Alert.*InpPushPlusToken|InpPushPlusToken.*InpPushPlusUrl" MQL5/Experts
```

Expected: tests PASS and both forbidden searches return no matches.

- [ ] **Step 6: Commit**

```powershell
git add -- MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5 tests/test_pushplus_ea_contract.py
git commit -m "feat: send confirmed reversals through PushPlus"
```

### Task 4: Documentation and Operator Setup

**Files:**
- Modify: `README.md`

**Interfaces:**
- Produces complete Chinese instructions for EA installation, WebRequest whitelist, Token entry, optional startup test, and troubleshooting.

- [ ] **Step 1: Add EA installation instructions**

Document copying EX5 to `MQL5\Experts`, adding `https://www.pushplus.plus` under Tools → Options → Expert Advisors, entering the Token, enabling Algo Trading, installing and logging in to the PushPlus App on one phone, enabling App notification sound, and confirming that no trading code exists.

- [ ] **Step 2: Add PushPlus status and failure guidance**

Explain empty Token, error 4014/URL whitelist, HTTP failure, business failure, async acceptance versus final App delivery, single-device App login, and that changing settings requires reloading the EA.

- [ ] **Step 3: Document privacy and test-message behavior**

State that Token is runtime-only and never committed; startup test is off by default; no real request was sent during development without explicit Token authorization.

- [ ] **Step 4: Run documentation checks and commit**

```powershell
rg -n "PushPlus|WebRequest|www.pushplus.plus|Token|MQL5\\\\Experts|算法交易|不.*交易" README.md
git add -- README.md
git commit -m "docs: add PushPlus EA setup guide"
```

### Task 5: Compile, Verify, and Deliver

**Files:**
- Create: `MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.ex5`
- Create: `verification/pushplus-ea-build-provenance.txt`

**Interfaces:**
- Produces a zero-warning EX5 matching the committed MQ5 and a desktop copy.

- [ ] **Step 1: Compile with MetaEditor**

Run MetaEditor 5 against the EA source with an explicit log. Expected: `Result: 0 errors, 0 warnings`.

- [ ] **Step 2: Run fresh full verification**

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
git diff --check
rg -n "TBD|TODO|FIXME" MQL5/Experts README.md tests verification
rg -n "OrderSend|CTrade|PositionOpen|trade\\.Buy|trade\\.Sell" MQL5/Experts
```

- [ ] **Step 3: Record compiler and hashes**

Write MetaEditor version, compile result, and SHA-256 for EA MQ5/EX5 to `verification/pushplus-ea-build-provenance.txt`; verify the recorded hashes match.

- [ ] **Step 4: Independently review the implementation**

Review against the approved design for network safety, one-shot behavior, JSON/UTF-8 correctness, response parsing, secret handling, and MQL5 runtime correctness. Fix all Critical and Important findings, then recompile and rerun verification.

- [ ] **Step 5: Commit final artifacts**

```powershell
git add -- MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.mq5 MQL5/Experts/XAUUSD_M5_Reversal_Alert_EA.ex5 README.md tests/test_pushplus_ea_contract.py verification/pushplus-ea-build-provenance.txt
git commit -m "chore: verify PushPlus alert EA"
```

- [ ] **Step 6: Copy the verified EX5 to the desktop**

Copy to `C:\Users\Administrator\Desktop\XAUUSD_M5_Reversal_Alert_EA.ex5`, compare SHA-256 with the repository EX5, and leave the existing indicator EX5 untouched.

- [ ] **Step 7: Send an explicitly authorized App-channel test**

Use the user-provided Token only in process memory to POST a connection test with `channel=app`. Print only the sanitized PushPlus business code, message, and request ID, never the Token or request body. Confirm the user receives the PushPlus App notification with system sound.
