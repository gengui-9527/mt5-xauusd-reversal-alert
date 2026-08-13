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


def required_seconds(score: float) -> float:
    _require_finite(score)
    return max(3.0, min(10.0, 10.0 - (abs(score) - 55.0) * 7.0 / 25.0))
