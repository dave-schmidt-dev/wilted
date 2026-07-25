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

   * **Requires a glob-home to exist.** ``map_entry`` makes an explicit tag
     *win over* globs by design, so a bare glob-miss cannot be the defect —
     otherwise every legitimate cross-area attribution (e.g. a
     ``processing_jobs.py`` execution-truthfulness bug tagged ``INV-6``, where
     ``processing_jobs.py`` sits in *no* invariant's area) would be flagged. The
     defect is only present when the files have a different, specific *glob-home*
     — the first charter-order invariant whose glob matches, i.e. the count
     ``map_entry`` would assign if the tag were absent — matching the plan's own
     words "move it off another one."
   * **Cutoff-filtered on the GLOB-HOME, like rule 1.** A re-tag only *harms*
     anything after the *glob-home's* ``resolved_at_date`` — that home is the
     count the re-tag dodges, so its cutoff (not the tagged invariant's) decides
     whether the dodge is live. Keying on the tag would let a re-tag onto a
     high-cutoff invariant hide a live recurrence of a low-cutoff home dated in
     the gap. Resolved-era-at-home entries are skipped as ``glob_only_mappings``
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
    the glob-only rule) are skipped. A tag naming an invariant *absent* from the
    charter is also skipped here — verified against ``map_entry`` (its
    ``entry.inv in by_id`` gate): an unknown tag is **not** honoured, it falls
    through to glob matching exactly like an untagged entry, so it still counts
    against its glob-home and creates no uncounted parking spot. It is therefore
    not a freeze-integrity risk; the residual gap (a *typo'd* tag whose intended
    invariant differs from its glob-home is silently ignored rather than
    reported) is typo hygiene, tracked as a TASKS.md follow-up, not caught here.

    Three conditions must all hold (see the module docstring for the rationale):

    1. The tagged invariant's ``area:`` globs match *none* of the cited files.
    2. Some invariant's globs match *at least one* cited file — the files have a
       specific *glob-home* (the invariant ``map_entry`` would assign if the tag
       were absent: the first charter-order invariant whose ``area:`` matches).
       Absent one, this is a legitimate cross-area attribution ``map_entry``
       honours by design, not a redirection.
    3. The entry survives the *glob-home's* resolution cutoff — NOT the tagged
       invariant's. A convenience re-tag dodges a count against the entry's real
       glob-home, so the "is this a live dodge?" question must key on the home's
       ``resolved_at_date``. Keying on the tag would let a re-tag onto a
       high-cutoff invariant mask a live recurrence of a low-cutoff home dated in
       the gap between them (the adversarial evasion this gate exists to stop).
       Resolved-era-at-home entries are archaeology, skipped as glob-only skips.
    """
    by_id = {inv.id: inv for inv in invs}
    findings: list[Finding] = []
    for entry in bugs:
        tag = entry.inv
        if not tag or tag == "NA" or tag not in by_id:
            continue
        if any(fnmatch(f, g) for f in entry.files for g in by_id[tag].area):
            continue  # (1) fails: tag is grounded in at least one touched file
        # (2) glob-home: first charter-order invariant whose area matches a cited
        # file — exactly map_entry's fall-through when the explicit tag is absent.
        glob_home = next(
            (inv for inv in invs if any(fnmatch(f, g) for f in entry.files for g in inv.area)),
            None,
        )
        if glob_home is None:
            continue  # (2) fails: files sit in no invariant's area — honest cross-area tag
        cutoff = led.resolved_after(glob_home.id)
        if cutoff and entry.date <= cutoff:
            continue  # (3) fails: pre-resolution at the glob-home, cannot dodge a live count
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
