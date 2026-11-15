# Vulture dead-code allowlist for the preparation runtime.
#
# The Python app (CLI, TUI, scheduler, station runtime, database) was retired on
# 2026-10-03; only the modules the native preparation worker loads remain
# (execution_capability, gguf_repair, llm, transcribe). The
# `[tool.vulture]` paths in pyproject.toml feed this file back into the scan so
# every name below counts as "used". `make deadcode` / the pre-commit hook fail
# only on NEW dead code past this list.
#
# Every entry names a symbol the worker uses dynamically (module attributes read
# through an injected module and the like, which vulture cannot see).
#
# ruff excludes this file (extend-exclude) -- bare names here are F821 to ruff.

create_backend  # used dynamically by llm_module.create_backend in Producer/Workers/wilted_worker/ad_corpus.py (src/wilted/llm.py:338)
execution_capability_scope  # used dynamically by Producer/Workers/wilted_pipeline.py and ad_corpus.py (src/wilted/execution_capability.py:53)
transcribe_audio  # used dynamically by transcribe.transcribe_audio in Producer/Workers/wilted_worker/transcript_sources.py (src/wilted/transcribe.py:128)
start_s  # read by Producer/Workers through the transcribe segment dataclass (src/wilted/transcribe.py)
end_s  # read by Producer/Workers through the transcribe segment dataclass (src/wilted/transcribe.py)
