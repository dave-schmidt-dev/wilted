# Invariants — wilted

> System contract. The harvest tool reads `area:` globs to map HISTORY bug entries
> to invariants. Per-project convention (commit prefix, invariant refs) is declared
> in this project's CLAUDE.md/README, not globally.

### INV-1 — All MLX/Metal GPU work is serialized behind `_model_lock`, and the tqdm lock is initialized on the main thread before Textual starts
area: ["src/wilted/engine.py", "src/wilted/tui/**/*.py", "src/wilted/cli.py"]
gate_test: tests/test_engine.py
threshold: 3
rationale: Concurrent Metal access (two threads in load/generate, or a lazy MLX generator escaping the lock) crashes the process with SIGABRT/SIGSEGV (BUG-1). First tqdm-lock init inside a Textual worker spawns resource_tracker with a bad fd set (BUG-2). Both are hard-won crashes; any unlocked MLX access or worker-thread tqdm init is a regression.

### INV-2 — At most one ML model is resident at a time, and every load is paired with a close that reclaims Metal memory even when the load fails
area: ["src/wilted/llm.py", "src/wilted/classify.py", "src/wilted/transcribe.py", "src/wilted/prepare.py", "src/wilted/ads.py", "src/wilted/engine.py"]
gate_test: tests/test_prepare.py
threshold: 3
rationale: The Phase-4 pipeline loads one model per family sequentially and unloads before the next. A load() that raises outside a try/finally, a close() that no-ops on partial load, or a second Metal model loaded while another is resident leaks GPU memory and risks OOM on Apple Silicon (M7, M8, M9, M20, M31).

### INV-3 — Destructive queue mutations target a stable item id resolved from the same query that produced the user-facing ordering — never a positional index into a differently-scoped query
area: ["src/wilted/cli.py", "src/wilted/queue.py", "src/wilted/tui/**/*.py"]
gate_test: tests/test_cli.py
threshold: 3
rationale: `load_queue()` shows `ready` + `selected` articles, but `remove_article(index)` deletes from a `ready`-only query, so the Nth displayed item is not the Nth deleted item — permanent loss of the wrong article (H3). This already bit the TUI once (2026-04-20 delete-by-id fix); the CLI call sites were never migrated.

### INV-4 — No pipeline stage persists empty or zero-byte output over an existing non-empty transcript or audio file; source-replacing writes are guarded against empty results and written atomically
area: ["src/wilted/prepare.py", "src/wilted/ads.py", "src/wilted/cache.py", "src/wilted/download.py"]
gate_test: tests/test_prepare.py
threshold: 3
rationale: When the LLM flags an entire clip as ad or every paragraph as promo, `cut_ads()` returns a 0-byte file and `remove_promos()` returns "", and prepare.py overwrites the original audio/transcript with it — silent, unrecoverable destruction of the prepared content (H1, H2).

### INV-5 — Runtime file paths resolve through the live `wilted.DATA_DIR` at call time, not a value captured at import, so tests never read or write the real `data/` tree
area: ["src/wilted/download.py", "src/wilted/prepare.py", "src/wilted/cache.py", "src/wilted/__init__.py", "tests/conftest.py"]
gate_test: tests/test_prepare.py
threshold: 3
rationale: `download.py` and `prepare.py` bind `from wilted import DATA_DIR` at import, so conftest's `monkeypatch.setattr(wilted, "DATA_DIR", ...)` never reaches them — `make test` already left stray transcripts in the real `data/transcripts/` tree, and a future unmocked test could overwrite production data (M3).

### INV-6 — Nightly pipeline stages isolate per-item and per-feed failures (one bad item cannot abort the batch), no user-facing entrypoint escapes with a raw traceback, and the nightly wrapper actually runs the pipeline and logs true exit codes
area: ["src/wilted/classify.py", "src/wilted/discover.py", "src/wilted/prepare.py", "src/wilted/report.py", "src/wilted/cli.py", "scripts/wilted-nightly.sh"]
gate_test: tests/test_classify.py
threshold: 3
rationale: `classify.py` has no per-item try/except so one bad LLM response aborts the whole stage (M4); chained/entry paths surface raw tracebacks (M37, M36); and the nightly wrapper invokes `python -m wilted.cli`, which has no `__main__` guard, so it exits 0 without running anything and logs "completed successfully" every night (C1).
