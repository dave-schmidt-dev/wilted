"""Tag-integrity audit over the closed-loop HISTORY/charter/ledger (plan D1).

This is a *governance* lint, not application code — it lives under ``tests/``
(like ``orthogonal_test_helpers.py``) so ``vulture`` (which scans ``src`` only)
never flags it, while ``ruff check .`` still lints it.

It reuses the shared harvest parser and mapping rules under ``~/.agent/harvest``
rather than reimplementing them, so the lint can never silently diverge from the
freeze logic it is meant to protect. Two failure shapes are detected:

1. **Glob-only phantom** — an *untagged* ``[bug]`` entry that maps to an
   invariant purely by ``area:`` glob and survives that invariant's resolution
   cutoff (i.e. is actively accumulating toward a freeze). Because
   ``harvest.recurrence.map_entry`` falls through to the *first* charter-order
   invariant whose glob matches, such an entry silently accrues against whatever
   invariant happens to be declared first (e.g. a progress-visibility bug landing
   on the model-lifecycle invariant). Delegated verbatim to
   ``harvest.recurrence.glob_only_mappings``.

2. **Convenience re-tag** — a ``[bug]`` entry carrying an explicit ``inv: INV-N``
   whose invariant's ``area:`` globs match *none* of the cited ``files:`` **while
   some other invariant's globs do** — i.e. the entry was moved *off* the
   invariant its files actually implicate and *onto* one they don't. Two
   deliberate narrowings from the naive "tag's globs miss its files":

   * **Requires another invariant to match.** ``map_entry`` makes an explicit tag
     *win over* globs by design, so a bare glob-miss cannot be the defect —
     otherwise every legitimate cross-area attribution (e.g. a
     ``processing_jobs.py`` execution-truthfulness bug tagged ``INV-6``, where
     ``processing_jobs.py`` sits in *no* invariant's area) would be flagged. The
     defect is only present when the files have a different, specific glob-home,
     matching the plan's own words "move it off another one."
   * **Cutoff-filtered, like rule 1.** A re-tag only *harms* anything after the
     tagged invariant's ``resolved_at_date`` (that is when it dodges a live
     count), so resolved-era entries are skipped exactly as ``glob_only_mappings``
     skips them.

   ``inv: NA`` is a legitimate non-regression marker and is never flagged.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass
from fnmatch import fnmatch
from pathlib import Path

_HARVEST_HOME = Path.home() / ".agent"


def harvest_available() -> bool:
    """True when the shared harvest package is importable on this machine.

    The harvest tooling is a per-user asset outside the repo, so a fresh clone
    or CI box may not have it. Callers skip cleanly when this is False.
    """
    return (_HARVEST_HOME / "harvest" / "__init__.py").exists()


def _ensure_harvest_on_path() -> None:
    root = str(_HARVEST_HOME)
    if root not in sys.path:
        sys.path.insert(0, root)


@dataclass(frozen=True)
class Finding:
    """One flagged HISTORY entry, reduced to the fields a message needs."""

    kind: str  # "glob_only" | "convenience_retag"
    date: str
    inv: str | None
    files: tuple[str, ...]
    text: str

    def describe(self) -> str:
        head = self.text[:100].rstrip()
        return f"[{self.kind}] {self.date} inv={self.inv or '(untagged)'} files={list(self.files)} :: {head}"


@dataclass(frozen=True)
class AuditResult:
    glob_only: tuple[Finding, ...]
    convenience_retags: tuple[Finding, ...]

    @property
    def clean(self) -> bool:
        return not self.glob_only and not self.convenience_retags

    def all_findings(self) -> tuple[Finding, ...]:
        return self.glob_only + self.convenience_retags

    def report(self) -> str:
        if self.clean:
            return "tag-integrity: clean"
        lines = [f"tag-integrity: {len(self.all_findings())} finding(s)"]
        lines += [f"  {f.describe()}" for f in self.all_findings()]
        return "\n".join(lines)


def _convenience_retags(bugs, invs, led) -> list[Finding]:
    """Entries moved *off* the invariant their files implicate onto one they don't.

    Mirrors ``harvest.recurrence.map_entry``'s notion of an explicit tag: only
    a real ``INV-N`` id is checked; ``inv: NA`` and untagged entries (handled by
    the glob-only rule) are skipped. A tag pointing at an invariant absent from
    the charter is left to charter-parse tooling, not flagged here.

    Three conditions must all hold (see the module docstring for the rationale):

    1. The tagged invariant's ``area:`` globs match *none* of the cited files.
    2. *Some other* invariant's globs match *at least one* cited file — the files
       have a different, specific glob-home, so this is a redirection rather than
       a legitimate cross-area attribution (which ``map_entry`` honours by design).
    3. The entry survives the tagged invariant's resolution cutoff — a re-tag only
       dodges a live count *after* ``resolved_at_date``; resolved-era entries are
       archaeology, skipped exactly as ``glob_only_mappings`` skips them.
    """
    by_id = {inv.id: inv for inv in invs}
    findings: list[Finding] = []
    for entry in bugs:
        tag = entry.inv
        if not tag or tag == "NA" or tag not in by_id:
            continue
        if any(fnmatch(f, g) for f in entry.files for g in by_id[tag].area):
            continue  # (1) fails: tag is grounded in at least one touched file
        other_home = any(fnmatch(f, g) for inv in invs if inv.id != tag for f in entry.files for g in inv.area)
        if not other_home:
            continue  # (2) fails: files sit in no invariant's area — honest cross-area tag
        cutoff = led.resolved_after(tag)
        if cutoff and entry.date <= cutoff:
            continue  # (3) fails: pre-resolution, cannot dodge a live count
        findings.append(
            Finding(
                kind="convenience_retag",
                date=entry.date,
                inv=tag,
                files=tuple(entry.files),
                text=entry.text,
            )
        )
    return findings


def audit(*, invariants_path: Path, history_path: Path, ledger_path: Path) -> AuditResult:
    """Run both tag-integrity rules over one repo's closed-loop documents.

    Raises:
        RuntimeError: When the harvest package is not importable — callers that
            want to skip on absence should gate on ``harvest_available()`` first.
    """
    if not harvest_available():
        raise RuntimeError(f"harvest package not found under {_HARVEST_HOME}")
    _ensure_harvest_on_path()

    from harvest.charter import parse_charter
    from harvest.history import parse_history
    from harvest.ledger_io import load_ledger
    from harvest.recurrence import glob_only_mappings

    invs = parse_charter(invariants_path)
    bugs = parse_history(history_path)
    led = load_ledger(ledger_path)

    glob_only = [
        Finding(
            kind="glob_only",
            date=e.date,
            inv=e.inv,
            files=tuple(e.files),
            text=e.text,
        )
        for e in glob_only_mappings(bugs, invs, led)
    ]
    return AuditResult(
        glob_only=tuple(glob_only),
        convenience_retags=tuple(_convenience_retags(bugs, invs, led)),
    )
