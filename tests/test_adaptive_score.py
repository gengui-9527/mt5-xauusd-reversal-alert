import math
import unittest
from unittest.mock import patch

from tests.adaptive_score_model import (
    ScoreSnapshot,
    clamp_unit,
    composite_score,
    ema_score,
    required_seconds,
    rsi_score,
    supertrend_score,
)


class AdaptiveScoreTests(unittest.TestCase):
    def test_clamp_unit_limits_each_side_of_the_unit_interval(self):
        self.assertEqual(clamp_unit(-2.0), -1.0)
        self.assertEqual(clamp_unit(0.25), 0.25)
        self.assertEqual(clamp_unit(2.0), 1.0)

    def test_component_extremes_and_rsi_neutral_boundaries(self):
        self.assertAlmostEqual(ema_score(101, 100, 100, 1), 35.0)
        self.assertAlmostEqual(ema_score(99, 100, 100, 1), -35.0)
        self.assertAlmostEqual(supertrend_score(101, 100, 1), 40.0)
        self.assertAlmostEqual(supertrend_score(99, 100, 1), -40.0)
        self.assertEqual(rsi_score(48), 0.0)
        self.assertEqual(rsi_score(50), 0.0)
        self.assertEqual(rsi_score(52), 0.0)
        self.assertEqual(rsi_score(60), 25.0)
        self.assertEqual(rsi_score(40), -25.0)

    def test_composite_exposes_immutable_components_and_clamps_total(self):
        score = composite_score(
            fast=105,
            slow=100,
            previous_completed_fast=99,
            price=110,
            supertrend_line=100,
            atr=1,
            rsi=80,
        )
        self.assertEqual(score, ScoreSnapshot(35.0, 40.0, 25.0, 100.0))
        with self.assertRaises(AttributeError):
            score.total = 0.0

    def test_composite_clamps_aggregate_beyond_both_total_bounds(self):
        cases = ((50.0, 60.0, 70.0, 100.0), (-50.0, -60.0, -70.0, -100.0))
        for ema, supertrend, rsi, expected_total in cases:
            with self.subTest(components=(ema, supertrend, rsi)):
                with (
                    patch("tests.adaptive_score_model.ema_score", return_value=ema),
                    patch(
                        "tests.adaptive_score_model.supertrend_score",
                        return_value=supertrend,
                    ),
                    patch("tests.adaptive_score_model.rsi_score", return_value=rsi),
                ):
                    score = composite_score(1, 1, 1, 1, 1, 1, 50)
                self.assertEqual(score.total, expected_total)

    def test_non_positive_or_non_finite_atr_is_rejected_before_scoring(self):
        for atr in (0.0, -1.0, math.nan, math.inf):
            with self.subTest(atr=atr):
                with self.assertRaises(ValueError):
                    composite_score(1, 1, 1, 1, 1, atr, 50)

    def test_non_finite_non_atr_inputs_are_rejected(self):
        for value in (math.nan, math.inf, -math.inf):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    ema_score(value, 100, 100, 1)
                with self.assertRaises(ValueError):
                    supertrend_score(value, 100, 1)
                with self.assertRaises(ValueError):
                    rsi_score(value)
                with self.assertRaises(ValueError):
                    required_seconds(value)

    def test_confirmation_time_is_bounded_and_monotonic_for_stronger_scores(self):
        values = [required_seconds(score) for score in (55, 60, 70, 80, 100)]
        self.assertEqual(values[0], 10.0)
        self.assertEqual(values[-1], 3.0)
        self.assertTrue(all(3.0 <= value <= 10.0 for value in values))
        self.assertEqual(values, sorted(values, reverse=True))


if __name__ == "__main__":
    unittest.main()
