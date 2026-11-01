"""Select recorded cuts only from a successful, source-matched preparation."""

from __future__ import annotations

import json
import math
import sqlite3
from pathlib import Path


def recorded_intervals(case: dict, *, library: Path) -> list[tuple[float, float]] | None:
    """Read the latest successful preparation matching the case's input identity.

    A case may additionally pin ``revisionID``. Failed attempts do not supersede
    a successful preparation, and another source's timeline never supplies cuts.
    A matching success with missing or invalid timing is unavailable rather than
    permission to silently fall back to an older preparation.

    Keys follow WiltedDomain/Preparation.swift's Codable terminal/evidence types
    and LocalLibraryStore.pipelineProvenanceEvidenceKind. The caller's score_case
    owns interval union and duration clamping, shared with replay scoring.
    """
    source_hash = case.get("sourceHash")
    revision_id = case.get("revisionID")
    if not isinstance(source_hash, str) or not source_hash or not library.is_file():
        return None
    if "revisionID" in case and (not isinstance(revision_id, str) or not revision_id):
        return None
    connection = sqlite3.connect(f"file:{library}?mode=ro", uri=True)
    try:
        rows = connection.execute(
            "SELECT CAST(ZSTATUSDATA AS TEXT) FROM ZPREPARATIONRECORD"
            " WHERE ZITEMID = ? ORDER BY ZEMITTEDAT DESC", (case["itemID"],)
        ).fetchall()
    finally:
        connection.close()
    for (blob,) in rows:
        try:
            status = json.loads(blob or "")
        except (ValueError, TypeError):
            continue
        if not isinstance(status, dict):
            continue
        terminal, evidence = status.get("terminalResult"), status.get("evidence")
        if not isinstance(terminal, dict) or terminal.get("outcome") != "succeeded":
            continue
        if revision_id is not None and terminal.get("revisionID") != revision_id:
            continue
        if not isinstance(evidence, dict) or evidence.get("kind") != "podcast-pipeline-provenance":
            continue
        fields = evidence.get("fields")
        if not isinstance(fields, dict) or fields.get("sourceHash") != source_hash:
            continue
        timeline = status.get("timeline")
        removed = timeline.get("removed") if isinstance(timeline, dict) else None
        if not isinstance(removed, list):
            return None
        result = []
        for entry in removed:
            if not isinstance(entry, dict):
                return None
            start, end = entry.get("originalStartSeconds"), entry.get("originalEndSeconds")
            if (type(start) not in (int, float) or type(end) not in (int, float)
                    or not math.isfinite(start) or not math.isfinite(end)
                    or not 0 <= start < end):
                return None
            result.append((float(start), float(end)))
        return result
    return None
