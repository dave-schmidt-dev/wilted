# Mac substrate spike — 2026-07-10 (Task 0.3)

**This is a disposable architecture spike. It is not production code.**

## Purpose

Compares two candidate substrates for the Mac-first personal radio station
controller (see the design doc's "Architecture decision framework",
`/Users/dave/Documents/Projects/.plans/wilted/mac-first-personal-radio-2026-07-10.md`
lines 40-51):

1. Retain the Python core, extract a headless station controller, keep
   Textual (or a thin replacement) as the Mac surface.
2. Extract a headless local station/content service from useful Python
   capabilities; build a native Swift client for macOS.

Both candidates run the exact same fixture and canonical action sequence
against the same committed, substrate-neutral station contract
(`src/wilted/station/models.py`, `reducer.py`, `protocols.py`) so their
results are comparable on state correctness, migration cost, and
testability. Three dimensions (Mac UX velocity, audio route recovery,
awake/sleep availability) are out of scope for this environment and are
marked `DEFERRED` in the scorecard — they need a real Mac/Xcode/device pass
that isn't available here.

## What's in this directory

| File | Purpose |
|---|---|
| `fixture.py` | Canonical mixed-media `StationEntry` fixtures (article, podcast, bulletin) plus `build_action_sequence()`, the ordered action script every candidate must execute identically. |
| `migration.py` | Read-only `Item` -> `StationEntry`/`MediaDescriptor` mapper, run against an isolated temp SQLite DB, to measure migration cost. Never opens the real `data/` DB. |
| `scorecard.py` | `Scorecard`/`ScorecardDimension` data structure and pretty-printers for the comparison writeup. |
| `measure.py` | Runs `fixture.py`'s action sequence through the committed reducer directly (no candidate substrate) and asserts the happy path completes at `OWNED_BY_IPHONE` with no rejections — proves the fixture itself is valid before either candidate consumes it. |

## Rules for anything built on top of this scaffold

- **Nothing under `src/wilted/` may import anything from `spikes/`.** This
  directory is removable at any time without touching production code or
  data (`grep -rn 'spikes' src/wilted` must stay empty).
- **Substrate-neutral, like the layer it builds on.** No `textual` import,
  no real-audio playback, no UI, no networking, no HTTP server.
- `migration.py` is the only file allowed to import `wilted.db`, and only
  against an isolated SQLite path it creates itself (temp dir) — never the
  real `data/wilted.db` (INV-5: tests/spikes must never read or write the
  real `data/` tree).
- Candidate spikes are separate directories/subagents built *on top of*
  this scaffold; they are not part of this commit.

## How to run the measurement

From the project root:

```bash
python spikes/mac-substrate-2026-07-10/measure.py
```

Expected: exits 0, prints the final lifecycle (`owned_by_iphone`), station
revision, acknowledged phone epoch, and a confirmation that no happy-path
rejection (`error`/`skip`) events were appended while running the fixture's
canonical action sequence through `wilted.station.reducer.apply()`.

To lint just this spike (it is intentionally outside `make validate`'s
scope):

```bash
ruff check spikes/mac-substrate-2026-07-10
```
