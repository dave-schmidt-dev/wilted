"""Negative-control matrix + live gate for the tag-integrity lint (plan D1).

The audit logic lives in :mod:`tests.tag_integrity_audit`; this file proves the
two detection rules are *sensitive* (they flag the shapes they must) and *not
over-eager* (they leave every legitimate shape clean). The single most important
case is :func:`test_honest_cross_area_tag_is_clean` — it is the exact
``processing_jobs.py → INV-6`` shape and is what separates the correct "refined"
reading of rule (ii) from the naive "literal" one. If a future edit relaxes the
lint back to literal, that test goes red; keep it.

All fixture cases drive the real parse → map pipeline through
:func:`tag_integrity_audit.audit` over temp charter/history/ledger files, so a
regression in the harvest parsers surfaces here too, not just in the lint.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from tag_integrity_audit import audit, harvest_available  # noqa: E402

pytestmark = pytest.mark.skipif(not harvest_available(), reason="harvest package not importable on this machine")

# Two invariants with disjoint, single-file areas plus one file (`orphan.py`)
# that sits in NEITHER — the three homes needed to exercise every branch.
_CHARTER = """\
### INV-A — alpha contract
area: ["src/pkg/alpha.py"]
gate_test: tests/test_alpha.py
threshold: 3

### INV-B — beta contract
area: ["src/pkg/beta.py"]
gate_test: tests/test_beta.py
threshold: 3
"""

# INV-A resolved at 07-15; entries dated after that accrue toward its freeze.
_LEDGER = """\
invariants:
  INV-A:
    gate_test_status: passing
  INV-B:
    gate_test_status: passing
resolutions:
  INV-A:
    resolved_at_date: "2026-07-15"
  INV-B:
    resolved_at_date: "2026-07-15"
"""


def _run(tmp_path: Path, history_body: str):
    """Write the three closed-loop docs and return the AuditResult."""
    (tmp_path / "INVARIANTS.md").write_text(_CHARTER)
    (tmp_path / "ledger.yaml").write_text(_LEDGER)
    (tmp_path / "HISTORY.md").write_text(history_body)
    return audit(
        invariants_path=tmp_path / "INVARIANTS.md",
        history_path=tmp_path / "HISTORY.md",
        ledger_path=tmp_path / "ledger.yaml",
    )


def _hist(*entries: str) -> str:
    return "## 2026-07-20\n\n" + "\n".join(entries) + "\n"


# --------------------------------------------------------------------------- #
# Rule 1 — glob-only phantom (untagged, maps by area glob alone).
# --------------------------------------------------------------------------- #


def test_glob_only_phantom_is_flagged(tmp_path):
    """Untagged bug touching INV-A's area, post-cutoff → flagged as glob_only."""
    res = _run(tmp_path, _hist("- [bug] untagged regression | files: src/pkg/alpha.py"))
    assert len(res.glob_only) == 1
    assert not res.convenience_retags
    assert res.glob_only[0].date == "2026-07-20"


def test_glob_only_before_cutoff_is_clean(tmp_path):
    """Same shape but dated on/before INV-A's cutoff → not counted, not flagged.

    Mirrors ``recurrence_counts``: a resolved-era entry cannot accrue toward a
    freeze, so the lint must not raise on it either (cutoff is exclusive).
    """
    body = "## 2026-07-15\n\n- [bug] resolved-era regression | files: src/pkg/alpha.py\n"
    res = _run(tmp_path, body)
    assert res.clean, res.report()


# --------------------------------------------------------------------------- #
# Rule 2 — convenience re-tag (explicit tag whose files' real home is elsewhere).
# --------------------------------------------------------------------------- #


def test_convenience_retag_is_flagged(tmp_path):
    """Bug tagged INV-A but touching only INV-B's file, post-cutoff → flagged.

    The files have a different, specific glob-home (INV-B), so the explicit
    INV-A tag is a redirection off the invariant they implicate.
    """
    res = _run(
        tmp_path,
        _hist("- [bug] moved off its home | files: src/pkg/beta.py | inv: INV-A"),
    )
    assert len(res.convenience_retags) == 1
    assert not res.glob_only
    assert res.convenience_retags[0].inv == "INV-A"


def test_convenience_retag_before_cutoff_is_clean(tmp_path):
    """A re-tag dated on/before the tagged invariant's cutoff cannot dodge a live
    count, so it is archaeology — not flagged (rule-2 cutoff filter)."""
    body = "## 2026-07-15\n\n- [bug] resolved-era retag | files: src/pkg/beta.py | inv: INV-A\n"
    res = _run(tmp_path, body)
    assert res.clean, res.report()


def test_honest_cross_area_tag_is_clean(tmp_path):
    """THE refined-vs-literal discriminator: a tag whose globs miss but whose
    files sit in NO other invariant's area is an honest cross-area attribution
    (the real ``processing_jobs.py → INV-6`` shape) and must stay clean.

    Under the naive "literal" reading (flag any tag whose globs miss its files)
    this would be flagged — which would force a dishonest re-tag or an
    area-widen, both forbidden. Keep this test as the guard against that
    regression.
    """
    res = _run(
        tmp_path,
        _hist("- [bug] truthfulness bug in an unmapped module | files: src/pkg/orphan.py | inv: INV-A"),
    )
    assert res.clean, res.report()


# --------------------------------------------------------------------------- #
# Shared controls — shapes both rules must leave clean.
# --------------------------------------------------------------------------- #


def test_na_sentinel_is_never_flagged(tmp_path):
    """`inv: NA` is a deliberate non-regression marker (area touched, contract
    not breached) — never a phantom or a convenience re-tag."""
    res = _run(
        tmp_path,
        _hist("- [bug] touched alpha, no breach | files: src/pkg/alpha.py | inv: NA"),
    )
    assert res.clean, res.report()


def test_grounded_tag_is_clean(tmp_path):
    """A tag that DOES match one of its cited files is grounded — clean even
    though the entry also cites files outside the invariant's area."""
    res = _run(
        tmp_path,
        _hist("- [bug] real INV-A breach | files: src/pkg/alpha.py, src/pkg/orphan.py | inv: INV-A"),
    )
    assert res.clean, res.report()


def test_non_bug_entry_is_ignored(tmp_path):
    """Only ``[bug]`` entries are harvested; features/changes never count and so
    are never linted, even when they touch an invariant's area untagged."""
    res = _run(
        tmp_path,
        _hist("- [feature] new alpha capability | files: src/pkg/alpha.py"),
    )
    assert res.clean, res.report()


# --------------------------------------------------------------------------- #
# Live gate — the real repo docs must be tag-clean. Skips on a fresh clone / CI
# box where the gitignored HISTORY.md (or the per-user harvest tool) is absent.
# --------------------------------------------------------------------------- #

_REPO = Path(__file__).resolve().parent.parent


def test_live_history_is_tag_clean():
    """Governance gate: the checked-out closed-loop docs carry no glob-only
    phantom and no convenience re-tag. Fails loudly with the offending entries
    so the author knows exactly what to tag.
    """
    history = _REPO / "HISTORY.md"
    if not history.exists():
        pytest.skip("HISTORY.md is gitignored and absent (fresh clone / CI)")
    res = audit(
        invariants_path=_REPO / "INVARIANTS.md",
        history_path=history,
        ledger_path=_REPO / "ledger.yaml",
    )
    assert res.clean, res.report()
