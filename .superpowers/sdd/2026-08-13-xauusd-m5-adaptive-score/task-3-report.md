# Task 3 Report: Incremental Supertrend Model and Replay Fixture

## Status

Implemented deterministic test/reference behavior only. No MQL production files
were changed.

## TDD Evidence

### Incremental Supertrend RED

Command:

```text
python -m unittest tests.test_incremental_supertrend -v
```

Expected failure:

```text
ImportError: cannot import name 'Bar' from 'tests.adaptive_score_model'
FAILED (errors=1)
```

This failed because the requested `Bar`, `SupertrendState`,
`advance_supertrend`, and `preview_supertrend` APIs did not exist.

### Incremental Supertrend GREEN

Command:

```text
python -m unittest tests.test_incremental_supertrend -v
```

Result:

```text
Ran 5 tests
OK
```

Coverage includes:

- sequential incremental recurrence versus an independent full replay to 1e-9;
- immutable, repeatable previews that retain the committed timestamp;
- committing the prior preview exactly once;
- rejection of duplicate and older commit times;
- reset/replay equality with fresh initialization.

### Replay RED

Command:

```text
python -m unittest tests.test_adaptive_replay -v
```

Expected failure:

```text
ModuleNotFoundError: No module named 'tools'
FAILED (errors=1)
```

This failed because the old-vs-new replay tool did not exist.

### Replay GREEN

Command:

```text
python -m unittest tests.test_adaptive_replay -v
```

Result:

```text
Ran 4 tests
OK
```

The committed fixture has exactly 120 fixed M5 rows:

- 30 rising;
- 20 top/bearish reversal;
- 30 falling;
- 20 V reversal;
- 20 alternating range.

The tests use literal fixture values and literal alert timestamps. Alert timing
and range counts are derived from actual emitted replay events rather than from
the report formatter or a shared expected-value helper.

## Replay Acceptance Output

Command:

```text
python tools/compare_adaptive_replay.py
```

Output:

```text
segment,legacy_alert_time,adaptive_alert_time,adaptive_lead_seconds,range_alert_count
top_reversal,1704076210,1704076203,7,0
v_reversal,1704091210,1704091203,7,0
range,,,,0
```

Acceptance results:

- adaptive is earlier on 2/2 marked clear reversals (majority required);
- adaptive range alerts: 0; legacy range alerts: 0;
- duplicate same-direction adaptive alerts: none;
- comparison exits 0.

## Final Verification

Commands:

```text
python -m unittest discover -s tests -v
python -m py_compile tests/adaptive_score_model.py tests/test_incremental_supertrend.py tests/test_adaptive_replay.py tools/compare_adaptive_replay.py
python tools/compare_adaptive_replay.py
git diff --check
```

Results:

- full suite: 62 tests, all passing;
- Python compilation: exit 0;
- replay comparison: exit 0 with the output above;
- diff check: exit 0, no whitespace errors;
- only an informational Windows LF-to-CRLF normalization warning was emitted.

## Self-review

- Supertrend recurrence uses multiplier 2.4 and the specified upper/lower
  carry-forward conditions.
- Long trend flips below final lower; short trend flips above final upper.
- Fixture loading validates the exact required CSV schema.
- Legacy behavior is a real EMA/Supertrend/RSI two-of-three vote followed by a
  10-second hold.
- Adaptive behavior uses the committed continuous score and confirmation APIs.
- Each M5 snapshot is held constant over deterministic one-second active
  observations through the ten-second confirmation boundary.
- The CLI returns nonzero for failed reversal-majority, range-count, or
  duplicate-direction acceptance.
- No network, current-date, broker, trading API, secret, or MQL change was
  introduced.

## Fix Round 1

### Review regressions: RED

The expanded replay tests were written before the fixes. The first focused run
failed at import with:

```text
ImportError: cannot import name 'build_report' from
'tools.compare_adaptive_replay'
FAILED (errors=1)
```

After implementing the lifecycle/report API but before changing the fixture,
the focused run had two expected failures:

```text
FAIL: test_graded_reversals_include_confirmation_longer_than_three_seconds
FAIL: test_range_creates_and_rewinds_candidate_without_alerting
Ran 11 tests
FAILED (failures=2)
```

A separate score-distribution regression failed for all three missing targets:

```text
test_fixture_exercises_scores_near_55_70_and_80
FAILED (failures=3)
```

These failures directly demonstrated that the original fixture saturated both
reversals at three seconds and never created a range candidate.

### Fix-round behavior: GREEN

- The replay now retains the committed Supertrend state through the current M5
  row, previews the current bar on every active tick, and commits that row once
  only when the next M5 row begins.
- Observation diagnostics prove all eleven offsets leave the committed state
  unchanged and that changing the committed prior bar changes the next preview.
- Expected directions are explicit: `top_reversal=-1`, `v_reversal=+1`.
  Report alert selection requires both matching segment and direction.
- A synthetic regression proves an earlier wrong-direction alert is ignored.
- CSV column order is checked exactly.
- Offsets `0..10` are explicitly tested and documented as eleven observations
  spanning ten elapsed one-second intervals.
- The fixed 120-row fixture retains the exact schema and segment sizes while
  adding first-tick absolute scores of 55, 70, and 80.
- Correct-direction adaptive confirmations now take 6 seconds bearish and
  4 seconds bullish, rather than both saturating at 3 seconds.
- Range evidence crosses entry, maintenance, and neutral zones: it creates a
  candidate, rewinds it, and clears it without an adaptive range alert.
- The CLI accepts zero or one fixture path. A supplied one-row failing fixture
  controls the report and returns exit 1; more than one argument returns usage
  error 2.

Focused replay output:

```text
segment,legacy_alert_time,adaptive_alert_time,adaptive_lead_seconds,range_alert_count
top_reversal,1704076210,1704076206,4,0
v_reversal,1704091210,1704091204,6,0
range,,,,0
```

Replay diagnostics:

```text
graded scores: [55.0, 70.0, 80.0]
adaptive reversal confirmations: bearish=6s, bullish=4s
range alerts: legacy=2, adaptive=0
duplicate adaptive directions: none
```

### Fix-round final verification

Commands:

```text
python -m unittest tests.test_incremental_supertrend tests.test_adaptive_replay -v
python tools/compare_adaptive_replay.py
python -m unittest discover -s tests -v
python -m py_compile tests/adaptive_score_model.py tests/test_incremental_supertrend.py tests/test_adaptive_replay.py tools/compare_adaptive_replay.py
git diff --check
```

Results:

- focused incremental/replay tests: 17 passed;
- default replay: exit 0 with 4-second bearish and 6-second bullish lead;
- full suite: 70 passed;
- Python compilation: exit 0;
- diff check: exit 0;
- informational Windows LF-to-CRLF normalization warnings only.
