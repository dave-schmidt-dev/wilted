"""Turn counted listener ad feedback into draft ad-corpus cases and labels.

The Mac and iPhone players record presses; each counts with its default label
unless the owner relabels or removes it in Settings > Ad feedback. This module writes manifest-ready draft cases and expected spans for
`adcorpus/manifest.json` without editing it, and never copies transcript text,
cue text, podcast prose or audio: `why` comes only from numbers and enum values.
Drafts carry show titles, so `--out` must point outside this public repository.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

import ad_corpus

DEFAULT_FEEDBACK = Path.home() / "Library" / "Application Support" / "Wilted" / "ad-feedback.json"
REPO_ROOT = Path(__file__).resolve().parents[2]
KIND_NAMES = {"adHere": "Ad here", "goodCut": "Good cut", "notAnAd": "Not an ad"}
SOURCE_NAMES = {"mac": "the Mac", "phone": "the iPhone"}
DEFAULT_LABELS = {"adHere": "must-cut", "goodCut": "must-cut", "notAnAd": "must-keep"}
STT_TODO = ("sttModel, segmentCount and transcriptEndSeconds are null: pin them from the "
            "aligned-STT cache with make ad-corpus-adopt")

class FeedbackError(RuntimeError):
    """The feedback file is missing, unreadable or from an unsupported version."""

def _number(value) -> bool:
    """True for a finite JSON number, excluding booleans."""
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
def _clock(seconds) -> str:
    """`m:ss` under an hour, `h:mm:ss` from an hour."""
    hours, rest = divmod(int(max(0.0, float(seconds))), 3600)
    minutes, secs = divmod(rest, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"
def _date(value) -> str | None:
    """The date part of an ISO 8601 string, or None when it is not one."""
    if not isinstance(value, str) or len(value) < 10:
        return None
    try:
        datetime.strptime(value[:10], "%Y-%m-%d")
    except ValueError:
        return None
    return value[:10]
def _timestamp(value) -> datetime:
    """A sortable timestamp; an unparseable or missing value sorts first."""
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return datetime.min.replace(tzinfo=timezone.utc)
def _iso_z(value) -> str:
    """Format a datetime (or parse an ISO string) as `...Z`."""
    if isinstance(value, str):
        try:
            return _iso_z(datetime.fromisoformat(value.replace("Z", "+00:00")))
        except ValueError:
            return value
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def load_feedback(path) -> list[dict]:
    """Read a listener ad-feedback file and return its entries.
    Args:
        path: Path to the app's `ad-feedback.json`.
    Returns:
        Entry dictionaries; unknown keys are ignored downstream.
    Raises:
        FeedbackError: Missing, invalid JSON, or a version other than 1.
    """
    path = Path(path)
    if not path.is_file():
        raise FeedbackError(f"no ad feedback at {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise FeedbackError(f"ad feedback at {path} is not valid JSON") from None
    if not isinstance(payload, dict) or payload.get("version") != 1:
        version = payload.get("version") if isinstance(payload, dict) else None
        raise FeedbackError(f"ad feedback version {version!r} is not supported (expected 1)")
    if not isinstance(entries := payload.get("entries"), list):
        raise FeedbackError(f"ad feedback at {path} has no entries list")
    return [entry for entry in entries if isinstance(entry, dict)]
def _counts(entry) -> bool:
    """True for a press that counts: filed presses count unless removed (`dismissed`) in Settings.

    `pending` comes only from files written before presses counted at once.
    """
    return isinstance(entry, dict) and entry.get("review") in ("accepted", "pending")
def _label_for(entry: dict) -> str | None:
    """The entry's explicit label, else the default for its kind."""
    explicit = entry.get("label")
    if isinstance(explicit, str) and explicit:
        return explicit
    return DEFAULT_LABELS.get(entry.get("kind"))
def _span_for(entry: dict) -> tuple[float, float, bool] | None:
    """`(start, end, needsTiming)` for one entry, or None when it cannot be placed."""
    cut = entry.get("nearestCut")
    if entry.get("kind") in ("goodCut", "notAnAd") and isinstance(cut, dict):
        start, end = cut.get("originalStartSeconds"), cut.get("originalEndSeconds")
        if _number(start) and _number(end):
            return round(float(start), 2), round(float(end), 2), False
    point = entry.get("originalSeconds")
    if _number(point):
        return round(max(0.0, float(point) - 15.0), 2), round(float(point) + 15.0, 2), True
    return None
def _why(entry: dict, *, count: int, needs_timing: bool) -> str:
    """One sentence built only from numbers and enum values in `entry`."""
    parts = [f"Listener marked {KIND_NAMES.get(entry.get('kind'), 'feedback')}"]
    if source := SOURCE_NAMES.get(entry.get("source")):
        parts.append(f"from {source}")
    if date := _date(entry.get("createdAt")):
        parts.append(f"on {date}")
    if _number(entry.get("playedSeconds")):
        parts.append(f"at {_clock(entry['playedSeconds'])} on the prepared audio")
    if _number(entry.get("originalSeconds")):
        parts.append(f"(original {_clock(entry['originalSeconds'])})")
    text = " ".join(parts)
    cut = entry.get("nearestCut")
    if isinstance(cut, dict):
        start, end = cut.get("originalStartSeconds"), cut.get("originalEndSeconds")
        if _number(start) and _number(end):
            named = f"{cut['label']} " if isinstance(cut.get("label"), str) and cut["label"] else ""
            text += f", next to the {named}cut {_clock(start)}-{_clock(end)}"
    engine = entry.get("engineVersion")
    if isinstance(engine, str) and engine:
        text += f"; engine {engine}"
    if count > 1:
        text += f" ({count} presses)"
    text += "."
    if needs_timing:
        text += " Retime to cue boundaries before adopting."
    return text

def expected_items(entries) -> list[dict]:
    """Merge feedback into manifest-ready expected spans, sorted by start.

    Entries for one item with the same label and identical start/end merge into
    one expected item carrying every feedback id. Each item has `itemID`,
    `start`, `end`, `label`, `why`, `feedbackIDs` and `needsTiming`.
    Args:
        entries: Feedback entries, normally already filtered to `accepted`.
    """
    groups: dict[tuple, list[dict]] = {}
    for entry in entries:
        span, label = _span_for(entry), _label_for(entry)
        if span is not None and label is not None:
            groups.setdefault((entry.get("itemID"), label, span[0], span[1]), []).append(entry)
    items = []
    for (item_id, label, start, end), members in groups.items():
        members.sort(key=lambda entry: _timestamp(entry.get("createdAt")))
        needs_timing = bool(_span_for(members[0])[2])
        items.append({
            "itemID": item_id, "start": start, "end": end, "label": label,
            "why": _why(members[0], count=len(members), needs_timing=needs_timing),
            "feedbackIDs": sorted(str(e["id"]) for e in members if e.get("id") is not None),
            "needsTiming": needs_timing,
        })
    return sorted(items, key=lambda i: (i["start"], i["end"], i["label"], str(i["itemID"])))

def library_facts(item_id, revision_id, *, library) -> dict:
    """Read preparation journal facts for one item and revision.
    Args:
        item_id: The library item identifier.
        revision_id: The preparation revision the feedback was pressed against.
        library: Path to the read-only library database.
    Returns:
        `recorded`, `audioDurationSeconds`, `sourceHash` and a `note` when they
        could not be read; missing files, tables and rows are not errors.
    """
    facts = {"recorded": [], "audioDurationSeconds": None, "sourceHash": None, "note": None}
    library = Path(library)
    if not library.is_file():
        facts["note"] = f"library facts unavailable: no library at {library}"
        return facts
    try:
        with contextlib.closing(sqlite3.connect(f"file:{library}?mode=ro", uri=True)) as db:
            rows = db.execute("SELECT CAST(ZSTATUSDATA AS TEXT) FROM ZPREPARATIONRECORD"
                              " WHERE ZITEMID = ? ORDER BY ZEMITTEDAT DESC",
                              (item_id,)).fetchall()
    except sqlite3.Error as error:
        facts["note"] = f"library facts unavailable: {error}"
        return facts
    for (blob,) in rows:
        try:
            status = json.loads(blob or "")
        except (ValueError, TypeError):
            continue
        terminal = status.get("terminalResult") if isinstance(status, dict) else None
        if not isinstance(terminal, dict) or terminal.get("outcome") != "succeeded" \
                or terminal.get("revisionID") != revision_id:
            continue
        timeline = status.get("timeline") if isinstance(status.get("timeline"), dict) else {}
        ends = [float(i["originalEndSeconds"]) for i in timeline.get("kept") or []
                if isinstance(i, dict) and _number(i.get("originalEndSeconds"))]
        for interval in timeline.get("removed") or []:
            start = interval.get("originalStartSeconds") if isinstance(interval, dict) else None
            end = interval.get("originalEndSeconds") if isinstance(interval, dict) else None
            if _number(start) and _number(end):
                facts["recorded"].append({
                    "start": round(float(start), 2), "end": round(float(end), 2),
                    "confidence": interval.get("confidence"), "label": interval.get("label")})
                ends.append(float(end))
        if ends:
            facts["audioDurationSeconds"] = round(max(ends), 2)
        evidence = status.get("evidence")
        if isinstance(evidence, dict) and evidence.get("kind") == "podcast-pipeline-provenance":
            fields = evidence.get("fields") if isinstance(evidence.get("fields"), dict) else {}
            source_hash = fields.get("sourceHash")
            facts["sourceHash"] = source_hash if isinstance(source_hash, str) and source_hash else None
        return facts
    facts["note"] = f"library facts unavailable: no succeeded preparation for revision {revision_id}"
    return facts

def _new_case(item_id, members: list[dict], items: list[dict], *, library: Path, now) -> dict:
    """Build one draft case from all accepted feedback for an unknown item."""
    ordered = sorted(members, key=lambda entry: _timestamp(entry.get("createdAt")))
    earliest = ordered[0]
    show = next((e["showTitle"] for e in ordered
                 if isinstance(e.get("showTitle"), str) and e["showTitle"]), "")
    facts = library_facts(item_id, earliest.get("revisionID"), library=library)
    created = [d for d in (_date(e.get("createdAt")) for e in ordered) if d]
    reviewed = [d for d in (_date(e.get("reviewedAt")) for e in ordered) if d]
    engines = sorted({e["engineVersion"] for e in ordered
                      if isinstance(e.get("engineVersion"), str) and e["engineVersion"]})
    todo = [STT_TODO]
    if point_labels := sum(1 for item in items if item["needsTiming"]):
        todo.append(f"retime {point_labels} point labels to cue boundaries")
    if facts["note"]:
        todo.append(facts["note"])
    item = str(item_id or "")
    stem = re.sub(r"[^a-z0-9]+", "-", show.lower()).strip("-")
    tag = item[5:13] if item.startswith("item-") else item[:8]
    return {
        "id": f"{stem}-feedback-{tag}" if stem else f"feedback-{tag}",
        "draft": True, "itemID": item_id, "show": show,
        "sourceHash": facts["sourceHash"], "sttModel": None, "segmentCount": None,
        "audioDurationSeconds": facts["audioDurationSeconds"], "transcriptEndSeconds": None,
        "intentionalCondition": "TODO: say what the detector got wrong or right here.",
        "reportedBy": ("Listener feedback from the player"
                       + (f", {min(created)}..{max(created)}" if created else "")),
        "provenance": {
            "labelledBy": "Owner feedback pressed while listening; accepted in the Mac review inbox.",
            "labelledOn": (max(reviewed) if reviewed else max(created) if created
                           else _date(_iso_z(now))),
            "inputIdentity": "TODO: pin the aligned-STT cache entry for sourceHash"
                             " with make ad-corpus-adopt.",
            "labelSource": "Player feedback (Ad here / Good cut / Not an ad) mapped to the"
                           " original timeline by the preparation journal.",
        },
        "engineVersions": engines, "recorded": facts["recorded"],
        "expected": items, "todo": todo,
    }

def build_drafts(entries, manifest, *, library, now) -> dict:
    """Build draft cases, additions and skips from feedback entries.
    Args:
        entries: All entries read from the file; every one not `dismissed` is used.
        manifest: The loaded ad-corpus manifest.
        library: Path to the read-only database.
        now: A datetime or ISO 8601 string, the generation time.
    Returns:
        `generatedAt`, `newCases`, `additions` and `skipped`.
    """
    counted = [e for e in entries if _counts(e)]
    skipped, usable = [], []
    for entry in counted:
        if _span_for(entry) is None:
            skipped.append({"id": entry.get("id"), "reason": "unmapped"})
        elif _label_for(entry) is None:
            skipped.append({"id": entry.get("id"), "reason": "unknown kind"})
        else:
            usable.append(entry)
    by_item: dict = {}
    for item in expected_items(usable):
        by_item.setdefault(item["itemID"], []).append(item)
    members: dict = {}
    for entry in counted:
        members.setdefault(entry.get("itemID"), []).append(entry)
    cases = {case["itemID"]: case for case in manifest.get("cases", [])
             if isinstance(case, dict) and case.get("itemID")}
    additions, new_cases = [], []
    for item_id, group in sorted(by_item.items(),
                                 key=lambda pair: (min(i["start"] for i in pair[1]), str(pair[0]))):
        clean = [{key: item[key] for key in
                  ("start", "end", "label", "why", "feedbackIDs", "needsTiming")}
                 for item in group]
        if item_id in cases:
            additions.append({"caseID": cases[item_id].get("id"), "itemID": item_id,
                              "expected": clean})
        else:
            new_cases.append(_new_case(item_id, members.get(item_id, []), clean,
                                       library=Path(library), now=now))
    return {"generatedAt": _iso_z(now), "newCases": new_cases, "additions": additions,
            "skipped": skipped}

def main(argv=None) -> int:
    """Run the exporter CLI.
    Args:
        argv: Argument list, or None to read `sys.argv`.
    Returns:
        0 when the feedback file was read, 2 otherwise.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feedback", type=Path, default=DEFAULT_FEEDBACK)
    parser.add_argument("--library", type=Path, default=ad_corpus.DEFAULT_LIBRARY)
    parser.add_argument("--manifest", type=Path, default=ad_corpus.MANIFEST)
    parser.add_argument("--out", type=Path, default=None,
                        help="write drafts here instead of stdout; must be outside the repository")
    args = parser.parse_args(argv)
    if args.out is not None:
        target = args.out.expanduser().resolve()
        if target.is_relative_to(REPO_ROOT):
            print(f"refusing to write drafts inside the repository: {target}", file=sys.stderr)
            return 2
    try:
        entries = load_feedback(args.feedback)
        manifest = ad_corpus.load_manifest(args.manifest)
    except FeedbackError as error:
        print(str(error), file=sys.stderr)
        return 2
    except (OSError, ValueError) as error:
        print(f"no ad corpus manifest at {args.manifest}: {error}", file=sys.stderr)
        return 2
    drafts = build_drafts(entries, manifest, library=args.library, now=datetime.now(timezone.utc))
    payload = {"generatedAt": drafts["generatedAt"], "feedback": str(args.feedback),
               "newCases": drafts["newCases"], "additions": drafts["additions"],
               "skipped": drafts["skipped"]}
    text = json.dumps(payload, indent=2) + "\n"
    if args.out is None:
        sys.stdout.write(text)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    needs_timing = sum(1 for collection in (payload["newCases"], payload["additions"])
                       for entry in collection for item in entry["expected"]
                       if item.get("needsTiming"))
    counted = sum(1 for e in entries if _counts(e))
    print(f"ad-feedback.drafts new_cases={len(payload['newCases'])}"
          f" additions={len(payload['additions'])} needs_timing={needs_timing}"
          f" skipped={len(payload['skipped'])} counted={counted}", file=sys.stderr)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
