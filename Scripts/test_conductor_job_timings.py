#!/usr/bin/env python3
"""Unit tests for conductor job timing summaries."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor_job_timings as timings  # noqa: E402

FOCUSED = (
    "acquired fair global heavy slot /tmp/x/global-heavy-0.lock after 2m 30s\n"
    "$ python3 Scripts/ci_app_test_runner.py --local\n"
    "Compiling RepoPromptApp Foo.swift\n"
    "\t Executed 4 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n"
)


class ParseTests(unittest.TestCase):
    def test_parse_duration(self) -> None:
        self.assertEqual(timings.parse_duration("60ms"), 0.06)
        self.assertEqual(timings.parse_duration("8s"), 8)
        self.assertEqual(timings.parse_duration("27m 52s"), 27 * 60 + 52)
        self.assertEqual(timings.parse_duration("1h 2m 3s"), 3723)

    def test_classify(self) -> None:
        self.assertEqual(timings.classify(FOCUSED), "test focused: app recompiled")
        full = FOCUSED.replace("Compiling RepoPromptApp Foo.swift\n", "").replace("Executed 4", "Executed 3021")
        self.assertEqual(timings.classify(full), "test full-suite: nothing compiled")
        self.assertEqual(timings.classify("$ Scripts/package_app.sh debug\n"), "package: no app compile")
        self.assertIsNone(timings.classify("random"))

    def test_sample_subtracts_wait(self) -> None:
        sample = timings.sample_log(FOCUSED, elapsed_seconds=400)
        self.assertEqual(sample.wait_seconds, 150)
        self.assertEqual(sample.net_seconds, 250)


class CollectTests(unittest.TestCase):
    def test_collect_and_summarize(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            jobs = Path(tmp) / "repo-hash" / "jobs"
            jobs.mkdir(parents=True)
            (jobs / "a.log").write_text(FOCUSED)
            (jobs / "b.log").write_text("acquired fair global heavy slot /tmp/l after 10s\njob canceled\n")
            (jobs / "c.log").write_text("unrelated\n")
            samples = timings.collect(Path(tmp), limit=10, elapsed=lambda _: 300.0)
        summary = timings.summarize(samples)
        self.assertEqual(summary["heavy-slot wait"]["n"], 2)
        self.assertEqual(summary["net test focused: app recompiled"]["p50_s"], 150.0)

    def test_percentile(self) -> None:
        self.assertEqual(timings.percentile([], 0.5), 0.0)
        self.assertEqual(timings.percentile([1, 2, 3, 4, 5], 0.5), 3)


if __name__ == "__main__":
    unittest.main()
