import csv
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from dataclasses import replace
from pathlib import Path

from tools.compare_adaptive_replay import (
    Alert,
    build_report,
    compare_replay,
    load_fixture,
)


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "xauusd_m5_adaptive_replay.csv"
COLUMNS = [
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
]


class AdaptiveReplayTests(unittest.TestCase):
    def test_committed_fixture_has_fixed_segment_shape_and_m5_spacing(self):
        rows = load_fixture(FIXTURE)

        self.assertEqual(
            Counter(row.segment for row in rows),
            {
                "rising": 30,
                "top_reversal": 20,
                "falling": 30,
                "v_reversal": 20,
                "range": 20,
            },
        )
        self.assertEqual(len(rows), 120)
        self.assertEqual(rows[0].time, 1_704_067_200)
        self.assertEqual(rows[-1].time, 1_704_102_900)
        self.assertTrue(
            all(later.time - earlier.time == 300 for earlier, later in zip(rows, rows[1:]))
        )

    def test_fixture_schema_rejects_correct_names_in_the_wrong_order(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wrong-order.csv"
            with path.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.writer(handle)
                writer.writerow([COLUMNS[1], COLUMNS[0], *COLUMNS[2:]])

            with self.assertRaisesRegex(ValueError, "columns"):
                load_fixture(path)

    def test_each_tick_previews_current_bar_without_mutating_prior_commit(self):
        rows = load_fixture(FIXTURE)
        result = compare_replay(rows[:3])

        self.assertEqual(len(result.observations), 33)
        self.assertEqual(
            {item.offset for item in result.observations if item.row_time == rows[1].time},
            set(range(11)),
        )
        self.assertEqual(
            {
                item.committed_time
                for item in result.observations
                if item.row_time == rows[1].time
            },
            {rows[0].time},
        )
        self.assertEqual(
            {
                item.preview_time
                for item in result.observations
                if item.row_time == rows[1].time
            },
            {rows[0].time},
        )
        self.assertEqual(
            {
                item.committed_time
                for item in result.observations
                if item.row_time == rows[2].time
            },
            {rows[1].time},
        )

    def test_committing_prior_bar_at_next_m5_boundary_changes_next_preview(self):
        rows = load_fixture(FIXTURE)[:2]
        baseline = compare_replay(rows)
        changed_prior = [replace(rows[0], high=2050.0, low=2048.0, close=2049.0), rows[1]]
        changed = compare_replay(changed_prior)

        baseline_next = next(
            item for item in baseline.observations
            if item.row_time == rows[1].time and item.offset == 0
        )
        changed_next = next(
            item for item in changed.observations
            if item.row_time == rows[1].time and item.offset == 0
        )
        self.assertNotEqual(baseline_next.supertrend_line, changed_next.supertrend_line)
        self.assertEqual(changed_next.committed_time, rows[0].time)

    def test_offsets_zero_through_ten_are_ten_elapsed_intervals(self):
        result = compare_replay(load_fixture(FIXTURE)[:1])
        offsets = [item.offset for item in result.observations]

        self.assertEqual(offsets, list(range(11)))
        self.assertEqual(offsets[-1] - offsets[0], 10)

    def test_wrong_direction_earlier_alert_cannot_satisfy_reversal_report(self):
        legacy = (
            Alert("top_reversal", 110, -1, 10),
            Alert("v_reversal", 210, 1, 10),
        )
        adaptive = (
            Alert("top_reversal", 101, 1, 3),
            Alert("top_reversal", 105, -1, 5),
            Alert("v_reversal", 201, -1, 3),
            Alert("v_reversal", 206, 1, 6),
        )

        reports = {row.segment: row for row in build_report(legacy, adaptive)}

        self.assertEqual(reports["top_reversal"].adaptive_alert_time, 105)
        self.assertEqual(reports["top_reversal"].adaptive_lead_seconds, 5)
        self.assertEqual(reports["v_reversal"].adaptive_alert_time, 206)
        self.assertEqual(reports["v_reversal"].adaptive_lead_seconds, 4)

    def test_graded_reversals_include_confirmation_longer_than_three_seconds(self):
        result = compare_replay(load_fixture(FIXTURE))
        correct_reversal_alerts = [
            alert
            for alert in result.adaptive_alerts
            if (alert.segment, alert.direction)
            in {("top_reversal", -1), ("v_reversal", 1)}
        ]

        self.assertEqual(len(correct_reversal_alerts), 2)
        self.assertTrue(
            any(alert.confirmation_seconds > 3 for alert in correct_reversal_alerts)
        )

    def test_fixture_exercises_scores_near_55_70_and_80(self):
        result = compare_replay(load_fixture(FIXTURE))
        first_tick_scores = [
            item.score for item in result.observations if item.offset == 0
        ]

        for target in (55, 70, 80):
            with self.subTest(target=target):
                self.assertTrue(
                    any(abs(abs(score) - target) <= 0.01 for score in first_tick_scores)
                )

    def test_range_creates_and_rewinds_candidate_without_alerting(self):
        result = compare_replay(load_fixture(FIXTURE))
        trace = [item for item in result.observations if item.segment == "range"]
        range_scores = [item.score for item in trace if item.offset == 0]
        candidate_points = [
            (index, item)
            for index, item in enumerate(trace)
            if item.pending_direction and item.confirmation_progress > 0
        ]

        self.assertTrue(any(abs(score) >= 55 for score in range_scores))
        self.assertTrue(any(35 <= abs(score) < 55 for score in range_scores))
        self.assertTrue(any(abs(score) < 35 for score in range_scores))
        self.assertTrue(candidate_points)
        self.assertTrue(
            any(
                later.pending_direction == point.pending_direction
                and later.confirmation_progress < point.confirmation_progress
                for index, point in candidate_points
                for later in trace[index + 1:]
            )
        )
        self.assertLessEqual(
            result.adaptive_range_alert_count,
            result.legacy_range_alert_count * 1.5,
        )
        self.assertEqual(result.adaptive_range_alert_count, 0)

    def test_correct_direction_reversals_are_adaptive_earlier_in_majority(self):
        result = compare_replay(load_fixture(FIXTURE))
        reports = {row.segment: row for row in result.rows}

        self.assertEqual(reports["top_reversal"].direction, -1)
        self.assertEqual(reports["v_reversal"].direction, 1)
        self.assertGreater(
            sum(
                reports[segment].adaptive_alert_time
                < reports[segment].legacy_alert_time
                for segment in ("top_reversal", "v_reversal")
            ),
            1,
        )
        self.assertEqual(result.duplicate_adaptive_directions, ())

    def test_cli_supplied_failing_fixture_controls_exit_status(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "no-reversals.csv"
            with FIXTURE.open(newline="", encoding="utf-8-sig") as source:
                reader = csv.DictReader(source)
                one_row = next(reader)
            with path.open("w", newline="", encoding="utf-8") as target:
                writer = csv.DictWriter(target, fieldnames=COLUMNS)
                writer.writeheader()
                writer.writerow(one_row)

            completed = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "tools" / "compare_adaptive_replay.py"),
                    str(path),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 1)
        self.assertIn("adaptive was not earlier", completed.stderr)

    def test_cli_default_fixture_prints_report_and_exits_successfully(self):
        completed = subprocess.run(
            [sys.executable, str(ROOT / "tools" / "compare_adaptive_replay.py")],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(
            "segment,legacy_alert_time,adaptive_alert_time,"
            "adaptive_lead_seconds,range_alert_count",
            completed.stdout,
        )


if __name__ == "__main__":
    unittest.main()
