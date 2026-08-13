import unittest

from tests.adaptive_score_model import (
    Bar,
    SupertrendState,
    advance_supertrend,
    preview_supertrend,
)


MULTIPLIER = 2.4


def full_replay(bars):
    """Independent batch reference used to catch broken incremental recurrence."""
    rows = []
    previous = None
    for bar in bars:
        midpoint = (bar.high + bar.low) / 2.0
        basic_upper = midpoint + MULTIPLIER * bar.atr
        basic_lower = midpoint - MULTIPLIER * bar.atr
        if previous is None:
            final_upper = basic_upper
            final_lower = basic_lower
            long_trend = bar.close >= midpoint
        else:
            final_upper = (
                previous["final_upper"]
                if basic_upper >= previous["final_upper"]
                and previous["previous_close"] <= previous["final_upper"]
                else basic_upper
            )
            final_lower = (
                previous["final_lower"]
                if basic_lower <= previous["final_lower"]
                and previous["previous_close"] >= previous["final_lower"]
                else basic_lower
            )
            long_trend = previous["long_trend"]
            if long_trend and bar.close < final_lower:
                long_trend = False
            elif not long_trend and bar.close > final_upper:
                long_trend = True
        previous = {
            "final_upper": final_upper,
            "final_lower": final_lower,
            "long_trend": long_trend,
            "previous_close": bar.close,
        }
        rows.append((previous, final_lower if long_trend else final_upper))
    return rows


class IncrementalSupertrendTests(unittest.TestCase):
    def setUp(self):
        self.bars = [
            Bar(300, 100.0, 101.1, 99.5, 100.8, 0.55),
            Bar(600, 100.8, 102.0, 100.4, 101.7, 0.58),
            Bar(900, 101.7, 102.1, 99.0, 99.2, 0.62),
            Bar(1200, 99.2, 99.6, 96.0, 96.4, 0.65),
            Bar(1500, 96.4, 100.2, 96.1, 99.9, 0.70),
            Bar(1800, 99.9, 103.4, 99.7, 103.0, 0.68),
        ]

    def test_incremental_states_and_lines_match_independent_full_replay(self):
        expected = full_replay(self.bars)
        state = None

        for bar, (expected_state, expected_line) in zip(self.bars, expected):
            state, line = advance_supertrend(state, bar)
            self.assertAlmostEqual(state.final_upper, expected_state["final_upper"], 9)
            self.assertAlmostEqual(state.final_lower, expected_state["final_lower"], 9)
            self.assertEqual(state.long_trend, expected_state["long_trend"])
            self.assertAlmostEqual(state.previous_close, expected_state["previous_close"], 9)
            self.assertEqual(state.committed_time, bar.time)
            self.assertAlmostEqual(line, expected_line, 9)

    def test_preview_is_repeatable_and_never_mutates_committed_state(self):
        committed, _ = advance_supertrend(None, self.bars[0])
        before = committed

        first_preview, first_line = preview_supertrend(committed, self.bars[1])
        second_preview, second_line = preview_supertrend(committed, self.bars[1])

        self.assertIs(committed, before)
        self.assertEqual(committed.committed_time, self.bars[0].time)
        self.assertEqual(committed.previous_close, self.bars[0].close)
        self.assertEqual(first_preview, second_preview)
        self.assertEqual(first_line, second_line)
        self.assertEqual(first_preview.committed_time, committed.committed_time)
        self.assertEqual(first_preview.previous_close, self.bars[1].close)

    def test_next_m5_bar_commits_the_prior_preview_exactly_once(self):
        state, _ = advance_supertrend(None, self.bars[0])
        preview, preview_line = preview_supertrend(state, self.bars[1])

        committed, committed_line = advance_supertrend(state, self.bars[1])

        self.assertEqual(
            (
                committed.final_upper,
                committed.final_lower,
                committed.long_trend,
                committed.previous_close,
            ),
            (
                preview.final_upper,
                preview.final_lower,
                preview.long_trend,
                preview.previous_close,
            ),
        )
        self.assertEqual(committed_line, preview_line)
        self.assertEqual(committed.committed_time, self.bars[1].time)
        with self.assertRaises(ValueError):
            advance_supertrend(committed, self.bars[1])

    def test_duplicate_or_older_commit_time_is_rejected(self):
        state, _ = advance_supertrend(None, self.bars[2])

        for bar in (self.bars[2], self.bars[1], self.bars[0]):
            with self.subTest(time=bar.time):
                with self.assertRaises(ValueError):
                    advance_supertrend(state, bar)

    def test_reset_and_replay_equals_fresh_initialization(self):
        state = None
        for bar in self.bars:
            state, line = advance_supertrend(state, bar)

        replayed = None
        for bar in self.bars:
            replayed, replayed_line = advance_supertrend(replayed, bar)

        fresh_expected, expected_line = full_replay(self.bars)[-1]
        self.assertEqual(state, replayed)
        self.assertEqual(line, replayed_line)
        self.assertEqual(
            replayed,
            SupertrendState(
                fresh_expected["final_upper"],
                fresh_expected["final_lower"],
                fresh_expected["long_trend"],
                fresh_expected["previous_close"],
                self.bars[-1].time,
            ),
        )
        self.assertAlmostEqual(replayed_line, expected_line, 9)


if __name__ == "__main__":
    unittest.main()
