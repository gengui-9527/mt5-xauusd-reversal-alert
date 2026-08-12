import unittest
from dataclasses import dataclass


def majority_vote(*votes: int) -> int:
    long_votes = sum(vote == 1 for vote in votes)
    short_votes = sum(vote == -1 for vote in votes)
    if long_votes >= 2:
        return 1
    if short_votes >= 2:
        return -1
    return 0


class SignalLogicTests(unittest.TestCase):
    def test_majority_vote_requires_two_matching_votes(self):
        self.assertEqual(majority_vote(1, 1, -1), 1)
        self.assertEqual(majority_vote(1, -1, -1), -1)
        self.assertEqual(majority_vote(1, -1, 0), 0)
        self.assertEqual(majority_vote(0, 1, 1), 1)
        self.assertEqual(majority_vote(0, -1, -1), -1)


@dataclass(frozen=True)
class State:
    confirmed: int = 0
    pending: int = 0
    pending_elapsed_ms: int = 0
    last_tick_ms: int = 0


def advance(
    state: State,
    candidate: int,
    tick_ms: int,
    hold_ms: int,
    max_tick_gap_ms: int,
):
    if state.confirmed == 0:
        if candidate == 0:
            return state, False
        return State(confirmed=candidate), False

    if candidate == 0 or candidate == state.confirmed:
        return State(confirmed=state.confirmed), False

    if state.pending != candidate:
        return State(
            confirmed=state.confirmed,
            pending=candidate,
            last_tick_ms=tick_ms,
        ), False

    delta_ms = tick_ms - state.last_tick_ms
    elapsed_ms = state.pending_elapsed_ms
    if 0 <= delta_ms <= max_tick_gap_ms:
        elapsed_ms += delta_ms

    if elapsed_ms < hold_ms:
        return State(
            confirmed=state.confirmed,
            pending=candidate,
            pending_elapsed_ms=elapsed_ms,
            last_tick_ms=tick_ms,
        ), False

    return State(confirmed=candidate), True


class ReversalStateTests(unittest.TestCase):
    def test_initial_direction_sets_baseline_without_alert(self):
        state, alert = advance(State(), 1, 1_000, 10_000, 1_000)
        self.assertEqual(state.confirmed, 1)
        self.assertFalse(alert)

    def test_reversal_requires_ten_seconds_of_active_ticks(self):
        state = State(confirmed=1)
        alert = False
        for tick_ms in range(1_000, 12_000, 1_000):
            state, alert = advance(state, -1, tick_ms, 10_000, 1_000)
        self.assertTrue(alert)
        self.assertEqual(state.confirmed, -1)

    def test_confirmed_direction_does_not_repeat_alert(self):
        state = State(confirmed=-1)
        state, alert = advance(state, -1, 12_000, 10_000, 1_000)
        self.assertFalse(alert)
        self.assertEqual(state.confirmed, -1)

    def test_neutral_or_original_direction_resets_pending_timer(self):
        state = State(confirmed=1)
        state, _ = advance(state, -1, 1_000, 10_000, 1_000)
        state, _ = advance(state, 0, 2_000, 10_000, 1_000)
        self.assertEqual(state.pending, 0)
        state, _ = advance(state, -1, 3_000, 10_000, 1_000)
        state, _ = advance(state, 1, 4_000, 10_000, 1_000)
        self.assertEqual(state.pending, 0)

    def test_no_tick_gap_does_not_advance_confirmation(self):
        state = State(confirmed=1)
        state, _ = advance(state, -1, 1_000, 10_000, 1_000)
        state, alert = advance(state, -1, 20_000, 10_000, 1_000)
        self.assertFalse(alert)
        self.assertEqual(state.pending_elapsed_ms, 0)

    def test_new_opposite_candidate_restarts_pending_state(self):
        state = State(confirmed=1, pending=-1, pending_elapsed_ms=2_000,
                      last_tick_ms=3_000)
        state, alert = advance(state, 0, 4_000, 10_000, 1_000)
        self.assertFalse(alert)
        self.assertEqual(state.pending, 0)
        self.assertEqual(state.pending_elapsed_ms, 0)


if __name__ == "__main__":
    unittest.main()
