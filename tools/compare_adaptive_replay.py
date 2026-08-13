#!/usr/bin/env python3
import csv
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tests.adaptive_score_model import (
    Bar,
    ConfirmationState,
    advance_confirmation,
    advance_supertrend,
    composite_score,
)


DEFAULT_FIXTURE = (
    Path(__file__).resolve().parents[1]
    / "tests"
    / "fixtures"
    / "xauusd_m5_adaptive_replay.csv"
)
CLEAR_REVERSALS = ("top_reversal", "v_reversal")


@dataclass(frozen=True)
class ReplayRow:
    segment: str
    time: int
    open: float
    high: float
    low: float
    close: float
    atr: float
    fast: float
    slow: float
    previous_fast: float
    rsi: float

    def bar(self) -> Bar:
        return Bar(
            self.time, self.open, self.high, self.low, self.close, self.atr
        )


@dataclass(frozen=True)
class Alert:
    segment: str
    time: int
    direction: int


@dataclass(frozen=True)
class ReportRow:
    segment: str
    legacy_alert_time: int | None
    adaptive_alert_time: int | None
    adaptive_lead_seconds: int | None
    range_alert_count: int


@dataclass(frozen=True)
class ReplayResult:
    rows: tuple[ReportRow, ...]
    legacy_alerts: tuple[Alert, ...]
    adaptive_alerts: tuple[Alert, ...]
    legacy_range_alert_count: int
    adaptive_range_alert_count: int
    duplicate_adaptive_directions: tuple[int, ...]


@dataclass
class _LegacyState:
    confirmed: int = 0
    pending: int = 0
    pending_since: int = 0


def load_fixture(path: Path | str = DEFAULT_FIXTURE) -> list[ReplayRow]:
    with Path(path).open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        required = {
            "segment",
            "time",
            "open",
            "high",
            "low",
            "close",
            "atr",
            "fast",
            "slow",
            "previous_fast",
            "rsi",
        }
        if set(reader.fieldnames or ()) != required:
            raise ValueError("replay fixture columns do not match the contract")
        return [
            ReplayRow(
                segment=row["segment"],
                time=int(row["time"]),
                open=float(row["open"]),
                high=float(row["high"]),
                low=float(row["low"]),
                close=float(row["close"]),
                atr=float(row["atr"]),
                fast=float(row["fast"]),
                slow=float(row["slow"]),
                previous_fast=float(row["previous_fast"]),
                rsi=float(row["rsi"]),
            )
            for row in reader
        ]


def _legacy_vote(row: ReplayRow, long_trend: bool) -> int:
    ema = (row.fast > row.slow) - (row.fast < row.slow)
    supertrend = 1 if long_trend else -1
    rsi = (row.rsi > 52.0) - (row.rsi < 48.0)
    votes = (ema, supertrend, rsi)
    if sum(vote == 1 for vote in votes) >= 2:
        return 1
    if sum(vote == -1 for vote in votes) >= 2:
        return -1
    return 0


def _advance_legacy(
    state: _LegacyState, direction: int, now: int
) -> tuple[_LegacyState, bool]:
    if state.confirmed == 0 and direction:
        state.confirmed = direction
        return state, False
    if direction == 0 or direction == state.confirmed:
        state.pending = 0
        state.pending_since = 0
        return state, False
    if direction != state.pending:
        state.pending = direction
        state.pending_since = now
        return state, False
    if now - state.pending_since >= 10:
        state.confirmed = direction
        state.pending = 0
        state.pending_since = 0
        return state, True
    return state, False


def _duplicate_directions(alerts: Iterable[Alert]) -> tuple[int, ...]:
    directions = [alert.direction for alert in alerts]
    return tuple(
        current
        for previous, current in zip(directions, directions[1:])
        if current == previous
    )


def compare_replay(rows: Iterable[ReplayRow]) -> ReplayResult:
    rows = list(rows)
    if not rows:
        raise ValueError("replay fixture must contain rows")

    supertrend_state = None
    legacy_state = _LegacyState()
    adaptive_state = ConfirmationState()
    legacy_alerts: list[Alert] = []
    adaptive_alerts: list[Alert] = []

    for row in rows:
        supertrend_state, line = advance_supertrend(supertrend_state, row.bar())
        legacy_direction = _legacy_vote(row, supertrend_state.long_trend)
        score = composite_score(
            row.fast,
            row.slow,
            row.previous_fast,
            row.close,
            line,
            row.atr,
            row.rsi,
        ).total

        # Tick zero plus ten elapsed one-second intervals lets a literal
        # ten-second legacy hold complete at offset 10.
        for offset in range(11):
            now = row.time + offset
            legacy_state, legacy_alerted = _advance_legacy(
                legacy_state, legacy_direction, now
            )
            if legacy_alerted:
                legacy_alerts.append(Alert(row.segment, now, legacy_direction))

            adaptive_state, adaptive_alerted = advance_confirmation(
                adaptive_state, score, now * 1_000
            )
            if adaptive_alerted:
                adaptive_alerts.append(
                    Alert(row.segment, now, adaptive_state.confirmed)
                )

    def first_time(alerts: list[Alert], segment: str) -> int | None:
        return next((alert.time for alert in alerts if alert.segment == segment), None)

    legacy_range_count = sum(
        alert.segment == "range" for alert in legacy_alerts
    )
    adaptive_range_count = sum(
        alert.segment == "range" for alert in adaptive_alerts
    )
    report_rows = []
    for segment in (*CLEAR_REVERSALS, "range"):
        legacy_time = first_time(legacy_alerts, segment)
        adaptive_time = first_time(adaptive_alerts, segment)
        lead = (
            legacy_time - adaptive_time
            if legacy_time is not None and adaptive_time is not None
            else None
        )
        report_rows.append(
            ReportRow(
                segment,
                legacy_time,
                adaptive_time,
                lead,
                adaptive_range_count if segment == "range" else 0,
            )
        )

    return ReplayResult(
        tuple(report_rows),
        tuple(legacy_alerts),
        tuple(adaptive_alerts),
        legacy_range_count,
        adaptive_range_count,
        _duplicate_directions(adaptive_alerts),
    )


def _format(value: int | None) -> str:
    return "" if value is None else str(value)


def print_report(result: ReplayResult) -> None:
    print(
        "segment,legacy_alert_time,adaptive_alert_time,"
        "adaptive_lead_seconds,range_alert_count"
    )
    for row in result.rows:
        print(
            ",".join(
                (
                    row.segment,
                    _format(row.legacy_alert_time),
                    _format(row.adaptive_alert_time),
                    _format(row.adaptive_lead_seconds),
                    str(row.range_alert_count),
                )
            )
        )


def acceptance_failures(result: ReplayResult) -> list[str]:
    reversal_rows = [
        row for row in result.rows if row.segment in CLEAR_REVERSALS
    ]
    earlier = sum(
        row.legacy_alert_time is not None
        and row.adaptive_alert_time is not None
        and row.adaptive_alert_time < row.legacy_alert_time
        for row in reversal_rows
    )
    failures = []
    if earlier <= len(reversal_rows) / 2:
        failures.append("adaptive was not earlier on a majority of clear reversals")
    if result.adaptive_range_alert_count > result.legacy_range_alert_count * 1.5:
        failures.append("adaptive range alerts exceed legacy x1.5")
    if result.duplicate_adaptive_directions:
        failures.append("adaptive emitted duplicate same-direction alerts")
    return failures


def main() -> int:
    result = compare_replay(load_fixture())
    print_report(result)
    failures = acceptance_failures(result)
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
