#!/usr/bin/env python3
"""Prints perf scenario summaries as one markdown table, a row per summary.

Usage: summarize.py SUMMARY.json [SUMMARY.json ...]

The app works out every percentile; this only formats. Several completed relaunch-check
summaries also get a line with launch.firstContent p50 and p95 across the launches.
Standard library only; runs on the Python 3.9 that ships with macOS.
"""
import json
import math
import os
import sys

SOURCES = ("memory", "memoryOther", "disk", "network")
DASH = "—"


def number(value, digits=1):
    if value is None:
        return DASH
    return f"{value:.{digits}f}"


def milliseconds(value):
    """Three significant digits or so: memory hits take microseconds, network misses seconds."""
    if value is None:
        return DASH
    for limit, digits in ((100, 0), (10, 1), (1, 2)):
        if value >= limit:
            return f"{value:.{digits}f}"
    return f"{value:.3f}"


def source_cell(stats):
    """p50 / p95 / max in ms, and how many."""
    if not stats or not stats.get("count"):
        return DASH
    return f"{milliseconds(stats.get('p50'))} / {milliseconds(stats.get('p95'))} / {milliseconds(stats.get('max'))} ({stats['count']})"


def nearest_rank(values, percent):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(percent / 100 * len(ordered)) - 1))]


def row(path, summary):
    measured = summary.get("measurements", {})
    thumbs = measured.get("thumbnails", {})
    display = thumbs.get("display", {})
    hitches = measured.get("hitches", {})
    hangs = measured.get("hangs", {})
    memory = measured.get("memory", {})
    trims = memory.get("trims") or []
    after_trim = ", ".join(number(trim.get("after2sMB")) for trim in trims) or DASH
    share = thumbs.get("sameFrameMemoryShare")
    placeholders = thumbs.get("placeholders", {})
    status = summary.get("status", "?")
    # The launch time in the file name tells several runs of one scenario apart.
    stamp = os.path.basename(path).rsplit("-", 1)[-1].replace(".json", "")
    run = f"{summary.get('scenario', '?')} s{summary.get('seed', '?')} {stamp}"
    if status != "completed":
        run += f" ({status})"
    return [
        run,
        summary.get("app", {}).get("build", "") or DASH,
        number(measured.get("window", {}).get("seconds")),
        *[source_cell(display.get(source)) for source in SOURCES],
        f"{share * 100:.1f} %" if share is not None else DASH,
        str(placeholders.get("total", DASH)),
        number(hitches.get("ratioMsPerSecond"), 2),
        number(hitches.get("longestMs")),
        str(hangs.get("count", DASH)),
        number(memory.get("peakMB")),
        after_trim,
        number(measured.get("launch", {}).get("firstContentMs"), 0),
    ]


HEADER = ["run", "build", "window s", *[f"{source} p50/p95/max ms (n)" for source in SOURCES],
          "same-frame memory", "placeholders", "hitch ms/s", "longest hitch ms", "hangs",
          "peak MB", "2 s after trim MB", "first content ms"]


def main(paths):
    if not paths:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    rows, launches = [], []
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                summary = json.load(handle)
        except (OSError, ValueError) as error:
            print(f"{path}: {error}", file=sys.stderr)
            return 1
        rows.append(row(path, summary))
        first = summary.get("measurements", {}).get("launch", {}).get("firstContentMs")
        if summary.get("scenario") == "relaunch-check" and summary.get("status") == "completed" and first is not None:
            launches.append(first)
    print("| " + " | ".join(HEADER) + " |")
    print("|" + "---|" * len(HEADER))
    for cells in rows:
        print("| " + " | ".join(cells) + " |")
    if len(launches) > 1:
        print()
        print(f"launch.firstContent over {len(launches)} launches: p50 {nearest_rank(launches, 50):.0f} ms, "
              f"p95 {nearest_rank(launches, 95):.0f} ms, max {max(launches):.0f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
