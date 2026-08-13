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
