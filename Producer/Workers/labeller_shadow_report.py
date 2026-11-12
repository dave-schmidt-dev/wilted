#!/usr/bin/env python3
"""Summarise the online ad labeller's shadow records.

Reads the per-episode JSON records the Mac app writes while the labeller runs
in shadow (``~/Library/Application Support/Wilted/ad-labeller-shadow/``) and
prints a plain-text report: how many episodes went to the provider and how many
stayed local (with the reason), failures by kind, how the labeller's proposed
breaks compare with the cuts the local engine made, and token use.

The records hold times and labels only. This tool prints episode IDs, never
titles, addresses or transcript text, and it sends nothing anywhere.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import Counter
from pathlib import Path

DEFAULT_DIRECTORY = (
    Path.home() / "Library/Application Support/Wilted/ad-labeller-shadow"
)
# Mean reasoning tokens per episode at the "low" level in the pre-trial run of 20
# longer episodes. Reasoning grows with episode length and that run did not
# separate low, high and default, so it is context, not a pass mark.
MEASURED_REASONING_TOKENS = 5500
REQUIRED_EPISODES = 30
REQUIRED_AD_FREE = 5


def load_records(directory: Path) -> tuple[list[dict], int]:
    """Return the readable records in ``directory`` and the count of unreadable files."""
    records: list[dict] = []
    unreadable = 0
    for path in sorted(directory.glob("*.json")):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            unreadable += 1
            continue
        if isinstance(record, dict) and record.get("schemaVersion") == 1:
            records.append(record)
        else:
            unreadable += 1
    return records, unreadable


def _spans(items: object) -> list[tuple[float, float]]:
    spans = []
    for item in items if isinstance(items, list) else []:
        try:
            start, end = float(item["start"]), float(item["end"])
        except (KeyError, TypeError, ValueError):
            continue
        if end > start:
            spans.append((start, end))
    return sorted(spans)


def _merged(spans: list[tuple[float, float]]) -> list[tuple[float, float]]:
    merged: list[tuple[float, float]] = []
    for start, end in sorted(spans):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def total_seconds(spans: list[tuple[float, float]]) -> float:
    """Seconds covered by ``spans``, counting overlapping time once."""
    return sum(end - start for start, end in _merged(spans))


def overlap_seconds(
    first: list[tuple[float, float]], second: list[tuple[float, float]]
) -> float:
    """Seconds covered by both span lists."""
    total = 0.0
    for a_start, a_end in _merged(first):
        for b_start, b_end in _merged(second):
            total += max(0.0, min(a_end, b_end) - max(a_start, b_start))
    return total


def compare(record: dict) -> dict:
    """Compare one remote record's proposed breaks with the engine's cuts."""
    engine = _spans(record.get("engineCutSpans"))
    breaks = (
        record.get("proposedBreaks")
        if isinstance(record.get("proposedBreaks"), list)
        else []
    )
    must_cut = _spans(
        [b for b in breaks if isinstance(b, dict) and b.get("label") == "must-cut"]
    )
    proposed = _spans(breaks)
    both = overlap_seconds(engine, must_cut)
    return {
        "episodeID": str(record.get("episodeID", "")),
        "engineSeconds": total_seconds(engine),
        "mustCutSeconds": total_seconds(must_cut),
        "proposedSeconds": total_seconds(proposed),
        "bothSeconds": both,
        "labellerOnlySeconds": total_seconds(must_cut) - both,
        "engineOnlySeconds": total_seconds(engine) - both,
        "breakCount": len(proposed),
        "rejectedCount": len(record.get("rejectedBreaks") or []),
        "reasoningTokens": record.get("reasoningTokens"),
        "requestSeconds": record.get("requestSeconds"),
    }


def _transport(record: dict) -> str:
    """The route that produced a record; records written before the field are ``direct``."""
    return str(record.get("transport") or "direct")


def _by_transport(labelled: list[dict]) -> dict:
    """Labelled count and median reasoning tokens for each transport."""
    groups: dict[str, list[dict]] = {}
    for record in labelled:
        groups.setdefault(_transport(record), []).append(record)
    result = {}
    for name, group in groups.items():
        tokens = [
            r["reasoningTokens"]
            for r in group
            if isinstance(r.get("reasoningTokens"), (int, float))
        ]
        result[name] = {
            "labelled": len(group),
            "medianReasoningTokens": statistics.median(tokens) if tokens else None,
        }
    return result


def summarise(records: list[dict]) -> dict:
    """Reduce the records to the counts and comparisons the report prints."""
    remote = [r for r in records if r.get("route") == "remote"]
    local = [r for r in records if r.get("route") == "local"]
    failed = [r for r in remote if r.get("failureKind")]
    labelled = [r for r in remote if not r.get("failureKind")]
    backfilled = [r for r in labelled if r.get("source") == "backfill"]
    engine_unknown = [r for r in labelled if r.get("engineOutcome") == "unknown"]
    rows = [compare(r) for r in labelled]
    reasoning = [
        row["reasoningTokens"]
        for row in rows
        if isinstance(row["reasoningTokens"], (int, float))
    ]
    seconds = [
        row["requestSeconds"]
        for row in rows
        if isinstance(row["requestSeconds"], (int, float))
    ]
    return {
        "episodes": len(records),
        "remote": len(remote),
        "local": len(local),
        "localReasons": dict(
            Counter(str(r.get("routeReason", "unknown")) for r in local)
        ),
        "failures": dict(Counter(str(r["failureKind"]) for r in failed)),
        "labelled": len(labelled),
        "backfilled": len(backfilled),
        "transports": _by_transport(labelled),
        "engineUnknown": len(engine_unknown),
        "adFree": sum(1 for row in rows if row["breakCount"] == 0),
        "requests": sum(int(r.get("requestCount") or 0) for r in remote),
        "promptTokens": sum(int(r.get("promptTokens") or 0) for r in labelled),
        "completionTokens": sum(int(r.get("completionTokens") or 0) for r in labelled),
        "medianReasoningTokens": statistics.median(reasoning) if reasoning else None,
        "medianRequestSeconds": statistics.median(seconds) if seconds else None,
        "rows": rows,
    }


def _clock(seconds: float) -> str:
    whole = int(round(seconds))
    return f"{whole // 60}:{whole % 60:02d}"


def render(summary: dict, unreadable: int) -> str:
    """Format ``summary`` as the plain-text report."""
    lines = [
        "Ad labeller shadow report",
        f"Episodes recorded: {summary['episodes']} "
        f"(sent to the provider: {summary['remote']}, stayed on this Mac: {summary['local']})",
    ]
    for reason, count in sorted(summary["localReasons"].items()):
        lines.append(f"  stayed local, {reason}: {count}")
    lines.append(
        f"Labelled without a failure: {summary['labelled']}, of which no ads found: {summary['adFree']}"
    )
    for name, group in sorted(summary["transports"].items()):
        line = f"  labelled via {name}: {group['labelled']}"
        if group["medianReasoningTokens"] is not None:
            line += f", median reasoning tokens {group['medianReasoningTokens']:.0f}"
        lines.append(line)
    if summary["backfilled"]:
        lines.append(f"Labelled from stored transcripts: {summary['backfilled']}")
    if summary["engineUnknown"]:
        lines.append(
            f"{summary['engineUnknown']} labelled episodes have no engine result on record; "
            "their engine column reads 0:00"
        )
    for kind, count in sorted(summary["failures"].items()):
        lines.append(f"  failed, {kind}: {count}")
    lines.append(
        f"Requests: {summary['requests']}; prompt tokens {summary['promptTokens']}, "
        f"completion tokens {summary['completionTokens']}"
    )
    if summary["medianReasoningTokens"] is not None:
        lines.append(
            f"Median reasoning tokens per episode: {summary['medianReasoningTokens']:.0f} "
            f"(the pre-trial run averaged about {MEASURED_REASONING_TOKENS} on longer episodes; "
            "reasoning grows with episode length, so this does not show whether the level is applied)"
        )
    if summary["medianRequestSeconds"] is not None:
        lines.append(f"Median request time: {summary['medianRequestSeconds']:.0f} s")
    enough = (
        summary["labelled"] >= REQUIRED_EPISODES
        and summary["adFree"] >= REQUIRED_AD_FREE
    )
    lines.append(
        f"Trial size: {'enough' if enough else 'not enough yet'} "
        f"(needs {REQUIRED_EPISODES} labelled episodes including {REQUIRED_AD_FREE} with no ads)"
    )
    if unreadable:
        lines.append(f"Unreadable record files skipped: {unreadable}")
    if summary["rows"]:
        lines += [
            "",
            "Per episode (minutes:seconds). 'both' = cut by the engine and marked must-cut by the labeller.",
            f"{'episode':<38} {'engine':>7} {'must-cut':>8} {'both':>7} {'labeller only':>13} "
            f"{'engine only':>11} {'breaks':>6} {'rejected':>8}",
        ]
        for row in sorted(
            summary["rows"],
            key=lambda r: -(r["labellerOnlySeconds"] + r["engineOnlySeconds"]),
        ):
            lines.append(
                f"{row['episodeID'][:38]:<38} {_clock(row['engineSeconds']):>7} "
                f"{_clock(row['mustCutSeconds']):>8} {_clock(row['bothSeconds']):>7} "
                f"{_clock(row['labellerOnlySeconds']):>13} {_clock(row['engineOnlySeconds']):>11} "
                f"{row['breakCount']:>6} {row['rejectedCount']:>8}"
            )
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    """Print the report for the records directory; exit 1 when there is none."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--directory",
        type=Path,
        default=DEFAULT_DIRECTORY,
        help="shadow records folder",
    )
    parser.add_argument("--json", action="store_true", help="print the summary as JSON")
    args = parser.parse_args(argv)
    if not args.directory.is_dir():
        print(f"No shadow records folder at {args.directory}", file=sys.stderr)
        return 1
    records, unreadable = load_records(args.directory)
    summary = summarise(records)
    if args.json:
        json.dump(
            {**summary, "unreadable": unreadable}, sys.stdout, indent=2, sort_keys=True
        )
        sys.stdout.write("\n")
    else:
        sys.stdout.write(render(summary, unreadable))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
