# Invariants — wilted

> System contract. The harvest tool reads `area:` globs to map HISTORY bug entries
> to invariants. Per-project convention (commit prefix, invariant refs) is declared
> in this project's CLAUDE.md/README, not globally.

### INV-1 — Remaining in-process MLX/Metal LLM work is serialized by ModelCoordinator's lease, and the tqdm lock is initialized on the main thread before Textual starts
area: ["src/wilted/engine.py", "src/wilted/tui/**/*.py", "src/wilted/cli.py", "src/wilted/station_runtime/coordinator.py"]
gate_test: tests/test_coordinator.py
# Gate references: TestModelCoordinator LLM lease serialization and TestRuntimeBootstrap main-thread tqdm-lock ordering.
threshold: 3
rationale: Concurrent in-process LLM Metal access crashes the process with SIGABRT/SIGSEGV (BUG-1). The speech daemon owns TTS Metal residency outside the Wilted process. First tqdm-lock init inside a Textual worker spawns resource_tracker with a bad fd set (BUG-2). Both are hard-won crashes; any unleased in-process LLM access or worker-thread tqdm init is a regression.

### INV-2 — At most one ML model is resident in the Wilted process at a time, and every load is paired with a close that reclaims Metal memory even when the load fails
area: ["src/wilted/llm.py", "src/wilted/classify.py", "src/wilted/transcribe.py", "src/wilted/prepare.py", "src/wilted/ads.py", "src/wilted/engine.py", "src/wilted/station_runtime/coordinator.py"]
gate_test: tests/test_prepare.py
# Additional gate reference: tests/test_coordinator.py (ModelCoordinator one-lease-at-a-time + close-on-exception; see TestOneModelAtATime, TestCloseRunsOnException)
threshold: 3
rationale: The Phase-4 pipeline loads one in-process model family sequentially and unloads before the next. Speech-daemon residency is outside the Wilted process. A load() that raises outside a try/finally, a close() that no-ops on partial load, or a second Metal model loaded while another is resident leaks GPU memory and risks OOM on Apple Silicon (M7, M8, M9, M20, M31).

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

### INV-6 — Nightly pipeline stages isolate per-item and per-feed failures (one bad item cannot abort the batch), no user-facing entrypoint escapes with a raw traceback, and every wrapper actually runs its pipeline/monitor and logs true exit codes
area: ["src/wilted/classify.py", "src/wilted/discover.py", "src/wilted/prepare.py", "src/wilted/report.py", "src/wilted/cli.py", "src/wilted/transcribe.py", "scripts/wilted-nightly.sh", "src/wilted/station_runtime/weather_monitor.py", "scripts/wilted-weather-monitor.sh"]
gate_test: tests/test_classify.py
# Additional gate reference: tests/test_weather_monitor.py (wrapper truthful-run/exit gate test — runpy-drives `python -m wilted.station_runtime.weather_monitor`'s `__main__` guard hermetically, via a monkeypatched `urllib.request.urlopen`, and asserts a real non-hardcoded exit code both on success and on a poll failure; also covers per-alert/per-poll failure isolation)
# Additional gate reference: tests/test_cli.py::TestMainEntrypoint::test_daemon_down_at_startup_raises_loudly (M2 daemon cutover — asserts a down/unreachable speech daemon at `cli.py main()` startup raises loudly for both the CLI and TUI entry points, PM-9) and tests/test_transcribe.py::TestTranscribeAudioExceptionContract + TestTranscribeAudioDaemonOnly (tier-3 STT daemon failures, including DaemonUnavailable, surface as typed TranscriptionError subclasses, never a raw AttributeError)
threshold: 3
rationale: `classify.py` has no per-item try/except so one bad LLM response aborts the whole stage (M4); chained/entry paths surface raw tracebacks (M37, M36); and the nightly wrapper invokes `python -m wilted.cli`, which has no `__main__` guard, so it exits 0 without running anything and logs "completed successfully" every night (C1). Task 4.2 (weather monitor) is a second, independent surface for the same C1 bug class: `weather_monitor.py` isolates a bad NWS fetch/parse and a malformed individual alert feature (never crashes the poll loop or propagates to the controller/TUI), and its `scripts/wilted-weather-monitor.sh` wrapper — mirroring `wilted-nightly.sh`'s shape — only exits 0 when `python -m wilted.station_runtime.weather_monitor`'s `__main__` guard actually ran a real poll and that poll itself recorded no error (`last_error is None`) — checked per-invocation, NOT via the 3-consecutive-failure `health()=="failed"` threshold, which a fresh one-shot process can never reach. M2 (daemon cutover) made tier-3 STT daemon-only: `transcribe.py` no longer has an isolated-spawn fallback, so a down daemon must surface as a typed `TranscriptionError` subclass (never a raw `AttributeError` from a `None` client) and `cli.py main()` gates both the TUI and CLI entrypoints on `client.require_daemon_ready(probe=True)` right after project-root validation — a down daemon must fail loudly at startup, not silently no-op or crash uninformatively deep in a command.

### INV-7 — The StationController's single drain thread is the sole caller of `reducer.apply`; every station mutation funnels through one command queue serviced by that one thread (SR-1 single-writer)
area: ["src/wilted/station_runtime/controller.py"]
gate_test: tests/test_station_controller.py
threshold: 3
rationale: `reducer.apply` is pure and centrally lease-checked, but that only yields a correct single-writer sequence if exactly one thread ever calls it. Two producers each reading revision N, both applying, and both persisting would let one silently lose the update — the store's compare-and-set catches the second only *because* the drain loop is the one serialization point in front of `apply`. Any second `apply` call site, or any producer that enqueues past the controller, reintroduces the lost-update/split-brain race the controller exists to prevent. Corollary (relied on by the persist path): `station_revision` advances on *every* accepted mutation and only on accepted mutations, so the controller can detect accept-vs-reject by the revision delta and the CAS fencing token stays monotonic (a Stop/handoff that changed lifecycle without bumping the revision was a real defect — a stopped station reloaded as playing, an acknowledged handoff was lost on disk).

### INV-8 — No code path other than the StationController writes station state; every mutation goes through `submit()` (compare-and-set on the pre-apply revision), never a direct `store.persist_state`/`persist_checkpoint` from a surface
area: ["src/wilted/station_runtime/controller.py", "src/wilted/tui/**"]
gate_test: tests/test_station_controller.py
# Additional gate reference: tests/test_tui.py::test_inv8_wilted_tui_source_never_references_legacy_resume_functions (AST scan for legacy resume/checkpoint functions; ensures TUI routes all mutations through controller.submit())
threshold: 3
rationale: A correctly-computed state written straight to the store bypasses both the central lease check and the compare-and-set fencing, reintroducing the split-brain that the controller's flock + single-writer queue exist to prevent. The lease claim in `ControllerLeaseManager.acquire` (the one deliberately unchecked write, per the reducer's `claim_lease` contract) and the store implementation itself are the only legitimate `persist_*` sites; a surface (TUI/CLI) must route through the controller. Enforcement completed in A.3.5 (commit ef0b015): TUI refactored to route all mutations through the controller, with call-site validation via AST-scan gate test ensuring no legacy direct-write paths remain.

### INV-9 — A transcript-backed entry's safe-interruption map is built by the production constructor with a non-zero tolerance band, so a live continuously-advancing playback offset can actually satisfy `safe_point_at` — and bulletin tests assert against that production construction, never only a hand-crafted stand-in
area: ["src/wilted/station_runtime/normalize.py", "src/wilted/station/models.py", "src/wilted/station/reducer.py", "src/wilted/tui/**/*.py"]
gate_test: tests/test_item_normalize.py
# Additional gate reference: tests/test_tui.py::test_bulletin_fires_with_production_built_safe_map_not_only_handcrafted_windows (drives the full submit chain with a `from_transcript_segments` map + a band=0 negative control proving the test would catch the shipped bug)
threshold: 3
rationale: The weather-bulletin interrupt gates on `safe_interruption.safe_point_at(live_offset)` in BOTH the TUI submitter (`_maybe_submit_pending_bulletin`) and the reducer, and HAZARD 2 requires the LIVE `adapter.current_offset_ms()` be the offset submitted — never a snapped/future boundary — or resume skips audio. `normalize.py` shipped `_SAFE_INTERRUPTION_BAND_MS = 0`, producing zero-width `(start_ms, start_ms)` windows; a continuously-advancing offset never lands on an exact boundary millisecond, so the bulletin silently NEVER interrupted real playback on David's Mac (2026-07-11) even though the whole suite was green. It stayed green because every bulletin test built its map with `SafeInterruptionMap.from_verified_windows()` and a hand-crafted WIDE window — never the production `from_transcript_segments()` path that shipped band=0 (a test-double divergence). Any regression to a zero/degenerate band, or a bulletin test that asserts only against a hand-crafted map instead of the production constructor, reintroduces the silent non-fire of a headline station feature. Fixed at band=1000 (commit 9f26b9a); the launch mode that decides whether the A.5.1 trigger is even watched is separately made visible (WARNING log + TUI `TEST-TRIGGER ARMED` line + `make station-test`, commit 89acc0a).
