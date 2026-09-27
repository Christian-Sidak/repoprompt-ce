#!/usr/bin/env python3
"""Summarize conductor job logs into build/test/queue timing percentiles.

Phase 0.1 baseline for docs/migrations/build-modularization-2026-09-28.md.
Durations are approximated from each job log's creation time to its last write,
minus the parsed global heavy-slot wait. This is a retroactive estimate over the
existing log format; structured per-phase timing inside conductor supersedes it.

Usage:
  conductor_job_timings.py [--state-root DIR] [--limit N] [--json]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence

DEFAULT_STATE_ROOT = Path.home() / "Library" / "Application Support" / "RepoPrompt CE" / "Conductor"
MAX_READ_BYTES = 400_000

_WAIT = re.compile(r"acquired fair global heavy slot \S+ after ([^\n]+)")
_EXECUTED = re.compile(r"Executed (\d+) tests?, with \d+ failures?")
_APP_COMPILE = re.compile(r"Compiling RepoPromptApp ")
_TEST_COMPILE = re.compile(r"Compiling RepoPromptTests ")


def parse_duration(text: str) -> float:
    """Parse conductor durations such as '60ms', '8.2s', '27m 52s', '1h 2m 3s'."""
    text = text.strip()
    milliseconds = re.fullmatch(r"(\d+(?:\.\d+)?)ms", text)
    if milliseconds:
        return float(milliseconds.group(1)) / 1000.0
    seconds = 0.0
    for value, unit in re.findall(r"(\d+(?:\.\d+)?)(h|m|s)\b", text):
        seconds += float(value) * {"h": 3600, "m": 60, "s": 1}[unit]
    return seconds


@dataclass(frozen=True)
class JobSample:
    category: str
    wait_seconds: Optional[float]
    net_seconds: Optional[float]


def classify(text: str) -> Optional[str]:
    executed = [int(n) for n in _EXECUTED.findall(text)]
    if "ci_app_test_runner" in text and executed:
        scope = "full-suite" if max(executed) >= 1000 else "focused"
        if _APP_COMPILE.search(text):
            return f"test {scope}: app recompiled"
        if _TEST_COMPILE.search(text):
            return f"test {scope}: tests recompiled"
        return f"test {scope}: nothing compiled"
    if "package_app" in text:
        return "package: app recompiled" if _APP_COMPILE.search(text) else "package: no app compile"
    return None


def sample_log(text: str, elapsed_seconds: float) -> Optional[JobSample]:
    wait_match = _WAIT.search(text)
    wait = parse_duration(wait_match.group(1)) if wait_match else None
    category = classify(text)
    if category is None and wait is None:
        return None
    net = elapsed_seconds - (wait or 0.0) if wait is not None else None
    if net is not None and net < 0:
        net = None
    return JobSample(category or "other", wait, net)


def file_elapsed(path: Path) -> float:
    stat = path.stat()
    born = getattr(stat, "st_birthtime", stat.st_ctime)
    return max(0.0, stat.st_mtime - born)


def iter_logs(state_root: Path, limit: int) -> List[Path]:
    logs = [p for p in state_root.glob("*/jobs/*.log") if p.is_file()]
    logs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return logs[:limit]


def percentile(values: Sequence[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    index = min(len(ordered) - 1, max(0, int(round(fraction * (len(ordered) - 1)))))
    return ordered[index]


def summarize(samples: Iterable[JobSample]) -> Dict[str, Dict[str, float]]:
    waits: List[float] = []
    by_category: Dict[str, List[float]] = {}
    for sample in samples:
        if sample.wait_seconds is not None:
            waits.append(sample.wait_seconds)
        if sample.category != "other" and sample.net_seconds is not None:
            by_category.setdefault(sample.category, []).append(sample.net_seconds)

    def stats(values: Sequence[float]) -> Dict[str, float]:
        return {
            "n": len(values),
            "p50_s": round(percentile(values, 0.5), 1),
            "p75_s": round(percentile(values, 0.75), 1),
            "p90_s": round(percentile(values, 0.9), 1),
        }

    summary = {"heavy-slot wait": stats(waits)}
    for category in sorted(by_category):
        summary[f"net {category}"] = stats(by_category[category])
    return summary


def collect(state_root: Path, limit: int, elapsed: Callable[[Path], float] = file_elapsed) -> List[JobSample]:
    samples = []
    for path in iter_logs(state_root, limit):
        try:
            with path.open("r", encoding="utf-8", errors="ignore") as handle:
                text = handle.read(MAX_READ_BYTES)
            sample = sample_log(text, elapsed(path))
        except OSError:
            continue
        if sample is not None:
            samples.append(sample)
    return samples


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--state-root", type=Path, default=DEFAULT_STATE_ROOT)
    parser.add_argument("--limit", type=int, default=3000)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if not args.state_root.is_dir():
        print(f"no conductor state at {args.state_root}", file=sys.stderr)
        return 1
    summary = summarize(collect(args.state_root, args.limit))
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        for name, row in summary.items():
            print(f"{name:40} n={int(row['n']):5}  p50={row['p50_s'] / 60:6.1f}m  "
                  f"p75={row['p75_s'] / 60:6.1f}m  p90={row['p90_s'] / 60:6.1f}m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
