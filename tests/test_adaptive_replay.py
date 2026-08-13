import subprocess
import sys
import unittest
from collections import Counter
from pathlib import Path

from tools.compare_adaptive_replay import compare_replay, load_fixture


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "xauusd_m5_adaptive_replay.csv"


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
        self.assertEqual(
            (rows[30].open, rows[30].close, rows[30].fast, rows[30].rsi),
            (2011.6, 2007.6, 2008.0, 38.0),
        )
        self.assertEqual(
            (rows[80].open, rows[80].close, rows[80].fast, rows[80].rsi),
            (1995.6, 2000.0, 1999.6, 62.0),
        )

    def test_clear_reversals_have_literal_legacy_and_adaptive_alert_times(self):
        result = compare_replay(load_fixture(FIXTURE))
        reports = {row.segment: row for row in result.rows}

        self.assertEqual(reports["top_reversal"].legacy_alert_time, 1_704_076_210)
        self.assertEqual(reports["top_reversal"].adaptive_alert_time, 1_704_076_203)
        self.assertEqual(reports["top_reversal"].adaptive_lead_seconds, 7)
        self.assertEqual(reports["v_reversal"].legacy_alert_time, 1_704_091_210)
        self.assertEqual(reports["v_reversal"].adaptive_alert_time, 1_704_091_203)
        self.assertEqual(reports["v_reversal"].adaptive_lead_seconds, 7)

    def test_replay_acceptance_compares_real_alert_events_and_range_counts(self):
        result = compare_replay(load_fixture(FIXTURE))
        reversal_rows = [
            row for row in result.rows if row.segment in {"top_reversal", "v_reversal"}
        ]

        self.assertGreater(
            sum(
                row.adaptive_alert_time < row.legacy_alert_time
                for row in reversal_rows
            ),
            len(reversal_rows) / 2,
        )
        self.assertLessEqual(
            result.adaptive_range_alert_count,
            result.legacy_range_alert_count * 1.5,
        )
        self.assertEqual(result.legacy_range_alert_count, 0)
        self.assertEqual(result.adaptive_range_alert_count, 0)
        self.assertEqual(result.duplicate_adaptive_directions, ())

    def test_cli_prints_report_and_exits_successfully(self):
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
        self.assertIn("top_reversal,1704076210,1704076203,7,0", completed.stdout)
        self.assertIn("v_reversal,1704091210,1704091203,7,0", completed.stdout)


if __name__ == "__main__":
    unittest.main()
