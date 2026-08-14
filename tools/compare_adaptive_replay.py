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
    preview_supertrend,
)


DEFAULT_FIXTURE = (
    Path(__file__).resolve().parents[1]
    / "tests"
    / "fixtures"
    / "xauusd_m5_adaptive_replay.csv"
)
CLEAR_REVERSALS = ("top_reversal", "v_reversal")
EXPECTED_DIRECTIONS = {"top_reversal": -1, "v_reversal": 1}
COLUMNS = (
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
)


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
    confirmation_seconds: int


@dataclass(frozen=True)
class ReportRow:
    segment: str
    direction: int
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
    observations: tuple["ReplayObservation", ...]
    legacy_snapshots: tuple["LegacySnapshot", ...]


@dataclass(frozen=True)
class ReplayObservation:
    segment: str
    row_time: int
    offset: int
    committed_time: int | None
    preview_time: int
    supertrend_line: float
    score: float
    pending_direction: int
    confirmation_progress: float


@dataclass(frozen=True)
class ConfirmationTracePoint:
    now_ms: int
    score: float
    pending_direction: int
    progress: float
    alerted: bool


@dataclass(frozen=True)
class LegacySnapshot:
    segment: str
    row_time: int
    ready: bool
    fast_ema: float | None
    slow_ema: float | None
    atr: float | None
    rsi: float | None
    supertrend_line: float | None
    long_trend: bool | None
    supertrend_vote: int
    direction: int


@dataclass
class _LegacyState:
    confirmed: int = 0
    pending: int = 0
    pending_elapsed: int = 0
    last_tick: int = 0
    has_last_tick: bool = False


def load_fixture(path: Path | str = DEFAULT_FIXTURE) -> list[ReplayRow]:
    with Path(path).open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        if tuple(reader.fieldnames or ()) != COLUMNS:
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


def _ema_series(rows: list[ReplayRow], period: int) -> list[float | None]:
    values: list[float | None] = [None] * len(rows)
    if not rows:
        return values
    alpha = 2.0 / (period + 1.0)
    ema = rows[0].close
    if period == 1:
        values[0] = ema
    for index in range(1, len(rows)):
        ema = alpha * rows[index].close + (1.0 - alpha) * ema
        if index >= period - 1:
            values[index] = ema
    return values


def _atr_series(rows: list[ReplayRow], period: int) -> list[float | None]:
    values: list[float | None] = [None] * len(rows)
    if len(rows) < period:
        return values
    true_ranges = []
    for index, row in enumerate(rows):
        previous_close = rows[index - 1].close if index else row.close
        true_ranges.append(
            max(
                row.high - row.low,
                abs(row.high - previous_close),
                abs(row.low - previous_close),
            )
        )
    atr = sum(true_ranges[:period]) / period
    values[period - 1] = atr
    for index in range(period, len(rows)):
        atr = (atr * (period - 1) + true_ranges[index]) / period
        values[index] = atr
    return values


def _rsi_series(rows: list[ReplayRow], period: int) -> list[float | None]:
    values: list[float | None] = [None] * len(rows)
    if len(rows) <= period:
        return values
    changes = [
        rows[index].close - rows[index - 1].close
        for index in range(1, len(rows))
    ]
    average_gain = sum(max(change, 0.0) for change in changes[:period]) / period
    average_loss = sum(max(-change, 0.0) for change in changes[:period]) / period

    def current_rsi() -> float:
        if average_loss == 0.0:
            return 100.0 if average_gain > 0.0 else 50.0
        if average_gain == 0.0:
            return 0.0
        relative_strength = average_gain / average_loss
        return 100.0 - 100.0 / (1.0 + relative_strength)

    values[period] = current_rsi()
    for index in range(period + 1, len(rows)):
        change = changes[index - 1]
        average_gain = (
            average_gain * (period - 1) + max(change, 0.0)
        ) / period
        average_loss = (
            average_loss * (period - 1) + max(-change, 0.0)
        ) / period
        values[index] = current_rsi()
    return values


def _legacy_snapshots(rows: list[ReplayRow]) -> tuple[LegacySnapshot, ...]:
    fast = _ema_series(rows, 9)
    slow = _ema_series(rows, 21)
    atr = _atr_series(rows, 10)
    rsi = _rsi_series(rows, 14)
    lines: list[float | None] = [None] * len(rows)
    trends: list[bool | None] = [None] * len(rows)
    upper = lower = previous_close = 0.0
    long_trend = False
    initialized = False
    for index, row in enumerate(rows):
        row_atr = atr[index]
        if row_atr is None:
            continue
        midpoint = (row.high + row.low) * 0.5
        basic_upper = midpoint + 3.0 * row_atr
        basic_lower = midpoint - 3.0 * row_atr
        if not initialized:
            upper = basic_upper
            lower = basic_lower
            long_trend = row.close >= midpoint
            initialized = True
        else:
            final_upper = (
                upper
                if basic_upper >= upper and previous_close <= upper
                else basic_upper
            )
            final_lower = (
                lower
                if basic_lower <= lower and previous_close >= lower
                else basic_lower
            )
            if long_trend and row.close < final_lower:
                long_trend = False
            elif not long_trend and row.close > final_upper:
                long_trend = True
            upper = final_upper
            lower = final_lower
        previous_close = row.close
        trends[index] = long_trend
        lines[index] = lower if long_trend else upper

    snapshots = []
    for index, row in enumerate(rows):
        ready = all(
            value is not None
            for value in (fast[index], slow[index], atr[index], rsi[index], lines[index])
        )
        supertrend_vote = 0
        direction = 0
        if ready:
            ema_vote = (fast[index] > slow[index]) - (fast[index] < slow[index])
            supertrend_vote = (row.close > lines[index]) - (
                row.close < lines[index]
            )
            rsi_vote = (rsi[index] > 50.0) - (rsi[index] < 50.0)
            votes = (ema_vote, supertrend_vote, rsi_vote)
            if sum(vote == 1 for vote in votes) >= 2:
                direction = 1
            elif sum(vote == -1 for vote in votes) >= 2:
                direction = -1
        snapshots.append(
            LegacySnapshot(
                row.segment,
                row.time,
                ready,
                fast[index],
                slow[index],
                atr[index],
                rsi[index],
                lines[index],
                trends[index],
                supertrend_vote,
                direction,
            )
        )
    return tuple(snapshots)


def _legacy_vote(snapshot: LegacySnapshot) -> int:
    if not snapshot.ready:
        return 0
    ema = (snapshot.fast_ema > snapshot.slow_ema) - (
        snapshot.fast_ema < snapshot.slow_ema
    )
    supertrend = snapshot.supertrend_vote
    rsi = (snapshot.rsi > 50.0) - (snapshot.rsi < 50.0)
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
        state.pending_elapsed = 0
        state.last_tick = 0
        state.has_last_tick = False
        return state, False
    if direction != state.pending:
        state.pending = direction
        state.pending_elapsed = 0
        state.last_tick = now
        state.has_last_tick = True
        return state, False
    delta = now - state.last_tick if state.has_last_tick and now >= state.last_tick else 0
    if delta <= 1:
        state.pending_elapsed += delta
    state.last_tick = now
    state.has_last_tick = True
    if state.pending_elapsed >= 10:
        state.confirmed = direction
        state.pending = 0
        state.pending_elapsed = 0
        state.last_tick = 0
        state.has_last_tick = False
        return state, True
    return state, False


def _duplicate_directions(alerts: Iterable[Alert]) -> tuple[int, ...]:
    directions = [alert.direction for alert in alerts]
    return tuple(
        current
        for previous, current in zip(directions, directions[1:])
        if current == previous
    )


def build_report(
    legacy_alerts: Iterable[Alert], adaptive_alerts: Iterable[Alert]
) -> tuple[ReportRow, ...]:
    legacy_alerts = tuple(legacy_alerts)
    adaptive_alerts = tuple(adaptive_alerts)

    def first_time(
        alerts: tuple[Alert, ...], segment: str, direction: int
    ) -> int | None:
        return next(
            (
                alert.time
                for alert in alerts
                if alert.segment == segment and alert.direction == direction
            ),
            None,
        )

    adaptive_range_count = sum(
        alert.segment == "range" for alert in adaptive_alerts
    )
    report_rows = []
    for segment in (*CLEAR_REVERSALS, "range"):
        direction = EXPECTED_DIRECTIONS.get(segment, 0)
        legacy_time = first_time(legacy_alerts, segment, direction)
        adaptive_time = first_time(adaptive_alerts, segment, direction)
        lead = (
            legacy_time - adaptive_time
            if legacy_time is not None and adaptive_time is not None
            else None
        )
        report_rows.append(
            ReportRow(
                segment,
                direction,
                legacy_time,
                adaptive_time,
                lead,
                adaptive_range_count if segment == "range" else 0,
            )
        )
    return tuple(report_rows)


def interrupted_range_trace() -> tuple[ConfirmationTracePoint, ...]:
    """Candidate interrupted at 8 elapsed seconds, before its 10s requirement."""
    scores = (-55.0,) * 9 + (-45.0,) + (0.0,) * 9
    state = ConfirmationState(confirmed=1)
    trace = []
    for tick, score in enumerate(scores):
        state, alerted = advance_confirmation(state, score, tick * 1_000)
        trace.append(
            ConfirmationTracePoint(
                tick * 1_000,
                score,
                state.pending,
                state.progress,
                alerted,
            )
        )
    return tuple(trace)


def compare_replay(rows: Iterable[ReplayRow]) -> ReplayResult:
    rows = list(rows)
    if not rows:
        raise ValueError("replay fixture must contain rows")

    legacy_snapshots = _legacy_snapshots(rows)
    supertrend_state = None
    legacy_state = _LegacyState()
    adaptive_state = ConfirmationState()
    legacy_alerts: list[Alert] = []
    adaptive_alerts: list[Alert] = []
    observations: list[ReplayObservation] = []
    previous_row: ReplayRow | None = None
    adaptive_pending_started_ms: int | None = None

    for row, legacy_snapshot in zip(rows, legacy_snapshots):
        if previous_row is not None:
            supertrend_state, _ = advance_supertrend(
                supertrend_state, previous_row.bar()
            )

        # Offsets 0..10 are eleven observations spanning exactly ten elapsed
        # one-second intervals, including both boundaries of the hold.
        for offset in range(11):
            preview_state, line = preview_supertrend(supertrend_state, row.bar())
            legacy_direction = _legacy_vote(legacy_snapshot)
            score = composite_score(
                row.fast,
                row.slow,
                row.previous_fast,
                row.close,
                line,
                row.atr,
                row.rsi,
            ).total
            now = row.time + offset
            legacy_state, legacy_alerted = _advance_legacy(
                legacy_state, legacy_direction, now
            )
            if legacy_alerted:
                legacy_alerts.append(Alert(row.segment, now, legacy_direction, 10))

            prior_pending = adaptive_state.pending
            adaptive_state, adaptive_alerted = advance_confirmation(
                adaptive_state, score, now * 1_000
            )
            if adaptive_state.pending and adaptive_state.pending != prior_pending:
                adaptive_pending_started_ms = now * 1_000
            elif not adaptive_state.pending and not adaptive_alerted:
                adaptive_pending_started_ms = None
            if adaptive_alerted:
                confirmation_seconds = (
                    int((now * 1_000 - adaptive_pending_started_ms) / 1_000)
                    if adaptive_pending_started_ms is not None
                    else 0
                )
                adaptive_alerts.append(
                    Alert(
                        row.segment,
                        now,
                        adaptive_state.confirmed,
                        confirmation_seconds,
                    )
                )
                adaptive_pending_started_ms = None
            observations.append(
                ReplayObservation(
                    row.segment,
                    row.time,
                    offset,
                    (
                        supertrend_state.committed_time
                        if supertrend_state is not None
                        else None
                    ),
                    preview_state.committed_time,
                    line,
                    score,
                    adaptive_state.pending,
                    adaptive_state.progress,
                )
            )
        previous_row = row

    legacy_range_count = sum(
        alert.segment == "range" for alert in legacy_alerts
    )
    adaptive_range_count = sum(
        alert.segment == "range" for alert in adaptive_alerts
    )
    return ReplayResult(
        build_report(legacy_alerts, adaptive_alerts),
        tuple(legacy_alerts),
        tuple(adaptive_alerts),
        legacy_range_count,
        adaptive_range_count,
        _duplicate_directions(adaptive_alerts),
        tuple(observations),
        legacy_snapshots,
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


def main(args: list[str] | None = None) -> int:
    args = sys.argv[1:] if args is None else args
    if len(args) > 1:
        print("usage: compare_adaptive_replay.py [fixture.csv]", file=sys.stderr)
        return 2
    fixture = Path(args[0]) if args else DEFAULT_FIXTURE
    result = compare_replay(load_fixture(fixture))
    print_report(result)
    failures = acceptance_failures(result)
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
