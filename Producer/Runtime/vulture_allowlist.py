# Vulture dead-code allowlist for the preparation runtime.
#
# The Python app (CLI, TUI, scheduler, station runtime, database) was retired on
# 2026-10-03; only the modules the native preparation worker loads remain
# (ads, cache, execution_capability, gguf_repair, llm, transcribe). The
# `[tool.vulture]` paths in pyproject.toml feed this file back into the scan so
# every name below counts as "used". `make deadcode` / the pre-commit hook fail
# only on NEW dead code past this list.
#
# Every entry names a symbol the worker uses dynamically (module attributes read
# through `ads_module.<name>` and the like, which vulture cannot see).
#
# ruff excludes this file (extend-exclude) -- bare names here are F821 to ruff.

AD_KIND_CREDITS  # used dynamically by ads_module.AD_KIND_CREDITS in Producer/Workers/wilted_worker/tail_recovery.py and ad_removal.py (src/wilted/ads.py:72)
_chunk_segments  # used dynamically by patched and read by name in Producer/Workers tests and wilted_worker (src/wilted/ads.py:822)
create_backend  # used dynamically by llm_module.create_backend in Producer/Workers/wilted_worker/ad_removal.py and ad_corpus.py (src/wilted/llm.py:338)
cut_ads  # used dynamically by ads_module.cut_ads in Producer/Workers/wilted_worker/ad_removal.py (src/wilted/ads.py:1488)
detect_ads  # used dynamically by ads_module.detect_ads in Producer/Workers/wilted_worker (nomination, commercial_recovery) (src/wilted/ads.py:1006)
execution_capability_scope  # used dynamically by Producer/Workers/wilted_pipeline.py and ad_corpus.py (src/wilted/execution_capability.py:53)
transcribe_audio  # used dynamically by transcribe.transcribe_audio in Producer/Workers/wilted_worker/transcript_sources.py (src/wilted/transcribe.py:128)
PROJECT_ROOT  # documented package attribute (README.md) with its own resolution tests; no production reader since DATA_DIR was pruned (src/wilted/__init__.py:11)
