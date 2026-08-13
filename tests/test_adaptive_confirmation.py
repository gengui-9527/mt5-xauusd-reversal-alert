import unittest

from tests.adaptive_score_model import (
    ConfirmationState,
    advance_confirmation,
)


class AdaptiveConfirmationTests(unittest.TestCase):
    def test_first_direction_sets_silent_long_baseline(self):
        state, alerted = advance_confirmation(ConfirmationState(), 70, 1_000)

        self.assertEqual(state.confirmed, 1)
        self.assertEqual(state.pending, 0)
        self.assertEqual(state.progress, 0.0)
        self.assertFalse(alerted)

    def test_strong_reversal_confirms_after_three_active_seconds(self):
        state = ConfirmationState(confirmed=1)
        for now in (1_000, 2_000, 3_000, 4_000):
            state, alerted = advance_confirmation(state, -80, now)

        self.assertTrue(alerted)
        self.assertEqual(state.confirmed, -1)
        self.assertEqual(state.pending, 0)

    def test_reversal_started_at_zero_confirms_after_three_active_seconds(self):
        state = ConfirmationState(confirmed=1)
        state, _ = advance_confirmation(state, -80, 0)
        for now in (1_000, 2_000, 3_000):
            state, alerted = advance_confirmation(state, -80, now)

        self.assertTrue(alerted)
        self.assertEqual(state.confirmed, -1)

    def test_zero_maximum_active_gap_is_rejected(self):
        with self.assertRaises(ValueError):
            advance_confirmation(
                ConfirmationState(), 70, 1_000, max_active_gap_ms=0
            )

    def test_maintenance_zone_rewinds_at_half_speed(self):
        state = ConfirmationState(
            confirmed=1, pending=-1, progress=0.60, last_tick_ms=1_000,
            has_last_tick=True,
        )

        state, alerted = advance_confirmation(state, -45, 2_000)

        self.assertAlmostEqual(state.progress, 0.55)
        self.assertFalse(alerted)

    def test_neutral_rewinds_at_normal_speed(self):
        state = ConfirmationState(
            confirmed=1, pending=-1, progress=0.60, last_tick_ms=1_000,
            has_last_tick=True,
        )

        state, _ = advance_confirmation(state, 0, 2_000)

        self.assertAlmostEqual(state.progress, 0.50)

    def test_explicit_opposite_evidence_clears_pending(self):
        state = ConfirmationState(
            confirmed=1, pending=-1, progress=0.60, last_tick_ms=1_000,
            has_last_tick=True,
        )

        state, _ = advance_confirmation(state, 40, 2_000)

        self.assertEqual(state.pending, 0)
        self.assertEqual(state.progress, 0.0)

    def test_inactive_tick_gap_never_advances(self):
        state = ConfirmationState(confirmed=1)
        state, _ = advance_confirmation(state, -80, 1_000)
        state, alerted = advance_confirmation(state, -80, 5_000)

        self.assertEqual(state.progress, 0.0)
        self.assertFalse(alerted)

    def test_entry_and_maintenance_thresholds_are_inclusive(self):
        state = ConfirmationState(confirmed=1, last_tick_ms=1_000, has_last_tick=True)
        state, _ = advance_confirmation(state, -55, 2_000)
        self.assertEqual(state.pending, -1)
        self.assertAlmostEqual(state.progress, 0.1)

        state, _ = advance_confirmation(state, -35, 3_000)
        self.assertAlmostEqual(state.progress, 0.05)

        state, _ = advance_confirmation(state, 35, 4_000)
        self.assertEqual(state.pending, 0)
        self.assertEqual(state.progress, 0.0)

        state, alerted = advance_confirmation(state, 55, 5_000)
        self.assertEqual(state.confirmed, 1)
        self.assertFalse(alerted)

    def test_confirmed_direction_never_repeats_an_alert(self):
        state = ConfirmationState(confirmed=1, last_tick_ms=1_000, has_last_tick=True)

        for now in (2_000, 3_000, 4_000, 5_000):
            state, alerted = advance_confirmation(state, 80, now)
            self.assertFalse(alerted)
            self.assertEqual(state.confirmed, 1)
            self.assertEqual(state.pending, 0)

    def test_new_candidate_replaces_an_unconfirmed_candidate(self):
        state = ConfirmationState(
            pending=1, progress=0.75, last_tick_ms=1_000, has_last_tick=True
        )

        state, alerted = advance_confirmation(state, -55, 2_000)

        self.assertEqual(state.pending, -1)
        self.assertEqual(state.progress, 0.1)
        self.assertFalse(alerted)

    def test_progress_is_clamped_to_the_unit_interval(self):
        state = ConfirmationState(
            confirmed=1, pending=-1, progress=0.98, last_tick_ms=1_000,
            has_last_tick=True,
        )

        state, alerted = advance_confirmation(state, -100, 2_000)

        self.assertEqual(state.progress, 0.0)
        self.assertEqual(state.pending, 0)
        self.assertEqual(state.confirmed, -1)
        self.assertTrue(alerted)

    def test_reconnect_reset_establishes_a_silent_baseline(self):
        state = ConfirmationState(
            confirmed=1, pending=-1, progress=0.80, last_tick_ms=1_000,
            has_last_tick=True,
        )

        state, alerted = advance_confirmation(state, -80, 100_000, reconnect_reset=True)

        self.assertEqual(state.confirmed, -1)
        self.assertEqual(state.pending, 0)
        self.assertEqual(state.progress, 0.0)
        self.assertFalse(alerted)


if __name__ == "__main__":
    unittest.main()
