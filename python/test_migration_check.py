"""Tests for migration_check. Run: python -m unittest discover python"""
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import migration_check as mc

HERE = Path(__file__).parent


def write_csv(dir_: Path, name: str, text: str) -> Path:
    path = dir_ / name
    path.write_text(text, encoding="utf-8")
    return path


class LoadCounts(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_normalizes_case_and_sums_duplicates(self):
        p = write_csv(self.tmp, "a.csv", "Account,Workload,Items\nAna@Contoso.com,Email,\"1,000\"\nana@contoso.com,email,5\n")
        self.assertEqual(mc.load_counts(p), {("ana@contoso.com", "email"): 1005})

    def test_rejects_missing_columns(self):
        p = write_csv(self.tmp, "a.csv", "account,items\nana@contoso.com,4\n")
        with self.assertRaisesRegex(ValueError, "workload"):
            mc.load_counts(p)

    def test_rejects_non_numeric_items_with_line_number(self):
        p = write_csv(self.tmp, "a.csv", "account,workload,items\nana@contoso.com,email,lots\n")
        with self.assertRaisesRegex(ValueError, ":2:"):
            mc.load_counts(p)

    def test_skips_blank_lines_and_handles_bom(self):
        p = write_csv(self.tmp, "a.csv", "﻿account,workload,items\n,,\nbo@contoso.com,drive,3\n")
        self.assertEqual(mc.load_counts(p), {("bo@contoso.com", "drive"): 3})


class Compare(unittest.TestCase):
    def test_statuses(self):
        src = {("a", "email"): 100, ("b", "email"): 100, ("c", "email"): 50, ("z", "email"): 0}
        tgt = {("a", "email"): 99, ("b", "email"): 98, ("d", "email"): 7, ("z", "email"): 0}
        status = {r.account: r.status for r in mc.compare(src, tgt, threshold=99.0)}
        self.assertEqual(status, {"a": "OK", "b": "BELOW_THRESHOLD", "c": "MISSING_IN_TARGET",
                                  "d": "NOT_IN_SOURCE", "z": "OK"})

    def test_extra_target_items_do_not_inflate_the_total(self):
        rows = mc.compare({("a", "email"): 100}, {("a", "email"): 130}, 99.0)
        self.assertEqual(mc.summarize(rows)["ALL"]["pct"], 100.0)


class EndToEnd(unittest.TestCase):
    def test_example_files_flag_the_shared_mailbox_and_missing_account(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = mc.main([str(HERE / "examples/source.csv"), str(HERE / "examples/target.csv")])
        text = out.getvalue()
        self.assertEqual(code, 1)
        self.assertIn("BELOW_THRESHOLD", text)
        self.assertIn("billing@contoso.com", text)
        self.assertIn("MISSING_IN_TARGET", text)
        self.assertIn("frontdesk@contoso.com", text)
        self.assertNotIn("ana@contoso.com", text.split("Needs review:")[1])

    def test_clean_run_exits_zero(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = mc.main([str(HERE / "examples/target.csv"), str(HERE / "examples/target.csv")])
        self.assertEqual(code, 0)
        self.assertIn("meets the threshold", out.getvalue())

    def test_bad_threshold_exits_two(self):
        self.assertEqual(mc.main(["x.csv", "y.csv", "--threshold", "150"]), 2)


if __name__ == "__main__":
    unittest.main()
