from dataclasses import dataclass
import math


EMA_DISTANCE_WEIGHT = 25.0
EMA_SLOPE_WEIGHT = 10.0
SUPERTREND_WEIGHT = 40.0
RSI_WEIGHT = 25.0


@dataclass(frozen=True)
class ScoreSnapshot:
    ema: float
    supertrend: float
    rsi: float
    total: float


@dataclass(frozen=True)
class ConfirmationState:
    confirmed: int = 0
    pending: int = 0
    progress: float = 0.0
    last_tick_ms: int = 0
    has_last_tick: bool = False


@dataclass(frozen=True)
class Bar:
    time: int
    open: float
    high: float
    low: float
    close: float
    atr: float


@dataclass(frozen=True)
class SupertrendState:
    final_upper: float
    final_lower: float
    long_trend: bool
    previous_close: float
    committed_time: int


def _require_finite(*values: float) -> None:
    if not all(math.isfinite(value) for value in values):
        raise ValueError("score inputs must be finite")


def _require_positive_atr(atr: float) -> None:
    _require_finite(atr)
    if atr <= 0.0:
        raise ValueError("atr must be positive")


def clamp_unit(value: float) -> float:
    _require_finite(value)
    return max(-1.0, min(1.0, value))


def ema_score(fast: float, slow: float, previous_completed_fast: float, atr: float) -> float:
    _require_finite(fast, slow, previous_completed_fast)
    _require_positive_atr(atr)
    distance = 25.0 * clamp_unit((fast - slow) / (0.20 * atr))
    slope = 10.0 * clamp_unit(
        (fast - previous_completed_fast) / (0.08 * atr)
    )
    return distance + slope


def supertrend_score(price: float, line: float, atr: float) -> float:
    _require_finite(price, line)
    _require_positive_atr(atr)
    return 40.0 * clamp_unit((price - line) / (0.50 * atr))


def rsi_score(rsi: float) -> float:
    _require_finite(rsi)
    if 48.0 <= rsi <= 52.0:
        return 0.0
    if rsi > 52.0:
        return 25.0 * clamp_unit((rsi - 52.0) / 8.0)
    return 25.0 * clamp_unit((rsi - 48.0) / 8.0)


def composite_score(
    fast: float,
    slow: float,
    previous_completed_fast: float,
    price: float,
    supertrend_line: float,
    atr: float,
    rsi: float,
) -> ScoreSnapshot:
    _require_finite(fast, slow, previous_completed_fast, price, supertrend_line, rsi)
    _require_positive_atr(atr)
    ema = ema_score(fast, slow, previous_completed_fast, atr)
    supertrend = supertrend_score(price, supertrend_line, atr)
    rsi_component = rsi_score(rsi)
    total = max(-100.0, min(100.0, ema + supertrend + rsi_component))
    return ScoreSnapshot(ema, supertrend, rsi_component, total)


def _next_supertrend(
    previous: SupertrendState | None,
    bar: Bar,
    *,
    committed_time: int,
    multiplier: float = 2.4,
) -> tuple[SupertrendState, float]:
    _require_finite(bar.open, bar.high, bar.low, bar.close, multiplier)
    _require_positive_atr(bar.atr)
    midpoint = (bar.high + bar.low) / 2.0
    basic_upper = midpoint + multiplier * bar.atr
    basic_lower = midpoint - multiplier * bar.atr

    if previous is None:
        final_upper = basic_upper
        final_lower = basic_lower
        long_trend = bar.close >= midpoint
    else:
        final_upper = (
            previous.final_upper
            if basic_upper >= previous.final_upper
            and previous.previous_close <= previous.final_upper
            else basic_upper
        )
        final_lower = (
            previous.final_lower
            if basic_lower <= previous.final_lower
            and previous.previous_close >= previous.final_lower
            else basic_lower
        )
        long_trend = previous.long_trend
        if long_trend and bar.close < final_lower:
            long_trend = False
        elif not long_trend and bar.close > final_upper:
            long_trend = True

    state = SupertrendState(
        final_upper, final_lower, long_trend, bar.close, committed_time
    )
    return state, final_lower if long_trend else final_upper


def advance_supertrend(
    state: SupertrendState | None,
    bar: Bar,
    *,
    multiplier: float = 2.4,
) -> tuple[SupertrendState, float]:
    if state is not None and bar.time <= state.committed_time:
        raise ValueError("bar time must advance beyond committed time")
    return _next_supertrend(state, bar, committed_time=bar.time, multiplier=multiplier)


def preview_supertrend(
    state: SupertrendState | None,
    current_bar: Bar,
    *,
    multiplier: float = 2.4,
) -> tuple[SupertrendState, float]:
    if state is not None and current_bar.time <= state.committed_time:
        raise ValueError("preview time must be newer than committed time")
    return _next_supertrend(
        state,
        current_bar,
        committed_time=state.committed_time if state is not None else 0,
        multiplier=multiplier,
    )


def required_seconds(score: float) -> float:
    _require_finite(score)
    return max(3.0, min(10.0, 10.0 - (abs(score) - 55.0) * 7.0 / 25.0))


def _score_direction(score: float, threshold: float) -> int:
    if score >= threshold:
        return 1
    if score <= -threshold:
        return -1
    return 0


def advance_confirmation(
    state: ConfirmationState,
    score: float,
    now_ms: int,
    *,
    entry_score: float = 55.0,
    maintenance_score: float = 35.0,
    maximum_confirmation_seconds: float = 10.0,
    max_active_gap_ms: int = 1_000,
    reconnect_reset: bool = False,
) -> tuple[ConfirmationState, bool]:
    """Advance confirmation using only the elapsed time between active ticks."""
    _require_finite(score, entry_score, maintenance_score, maximum_confirmation_seconds)
    if not 0.0 < maintenance_score < entry_score:
        raise ValueError("confirmation thresholds must be ordered and positive")
    if maximum_confirmation_seconds <= 0.0 or max_active_gap_ms <= 0:
        raise ValueError("confirmation timing must be positive")

    if reconnect_reset:
        state = ConfirmationState()

    entry_direction = _score_direction(score, entry_score)
    if state.confirmed == 0 and state.pending == 0 and entry_direction:
        return ConfirmationState(
            confirmed=entry_direction, last_tick_ms=now_ms, has_last_tick=True
        ), False

    delta_ms = now_ms - state.last_tick_ms if state.has_last_tick else 0
    active_seconds = (
        delta_ms / 1_000.0 if 0 <= delta_ms <= max_active_gap_ms else 0.0
    )
    last_tick_ms = now_ms

    if entry_direction == state.confirmed:
        return ConfirmationState(
            confirmed=state.confirmed, last_tick_ms=last_tick_ms, has_last_tick=True
        ), False

    if entry_direction and entry_direction != state.pending:
        progress = active_seconds / required_seconds(score)
        return ConfirmationState(
            confirmed=state.confirmed,
            pending=entry_direction,
            progress=max(0.0, min(1.0, progress)),
            last_tick_ms=last_tick_ms,
            has_last_tick=True,
        ), False

    if state.pending == 0:
        return ConfirmationState(
            confirmed=state.confirmed, last_tick_ms=last_tick_ms, has_last_tick=True
        ), False

    maintenance_direction = _score_direction(score, maintenance_score)
    if maintenance_direction == -state.pending:
        return ConfirmationState(
            confirmed=state.confirmed, last_tick_ms=last_tick_ms, has_last_tick=True
        ), False

    if entry_direction == state.pending:
        progress = state.progress + active_seconds / required_seconds(score)
        if progress >= 1.0:
            return ConfirmationState(
                confirmed=state.pending, last_tick_ms=last_tick_ms, has_last_tick=True
            ), True
    elif maintenance_direction == state.pending:
        progress = state.progress - active_seconds / maximum_confirmation_seconds * 0.5
    else:
        progress = state.progress - active_seconds / maximum_confirmation_seconds

    progress = max(0.0, min(1.0, progress))
    pending = state.pending if progress > 0.0 else 0
    return ConfirmationState(
        confirmed=state.confirmed,
        pending=pending,
        progress=progress,
        last_tick_ms=last_tick_ms,
        has_last_tick=True,
    ), False
