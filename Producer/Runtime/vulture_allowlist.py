# Vulture dead-code allowlist for the preparation runtime.
#
# The Python app (CLI, TUI, scheduler, station runtime, database) was retired on
# 2026-10-03; only the modules the native preparation worker loads remain
# (ads, cache, execution_capability, feed_refs, gguf_repair, llm, text,
# transcribe). The `[tool.vulture]` paths in pyproject.toml feed this file back
# into the scan so every name below counts as "used". `make deadcode` / the
# pre-commit hook fail only on NEW dead code past this list.
#
# Two kinds of entry: names the worker uses dynamically (module attributes read
# through `ads_module.<name>` and the like, which vulture cannot see), and
# public functions whose only callers were in the retired app. The second kind
# is retained with its tests on purpose (the retirement removed exactly the app
# surface); delete an entry together with its function and tests.
#
# ruff excludes this file (extend-exclude) -- bare names here are F821 to ruff.

AD_KIND_CREDITS  # used dynamically by ads_module.AD_KIND_CREDITS in Producer/Workers/wilted_worker/tail_recovery.py and ad_removal.py (src/wilted/ads.py:75)
_chunk_segments  # used dynamically by patched and read by name in Producer/Workers tests and wilted_worker (src/wilted/ads.py:825)
clean_text  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/text.py:6)
create_backend  # used dynamically by llm_module.create_backend in Producer/Workers/wilted_worker/ad_removal.py and ad_corpus.py (src/wilted/llm.py:338)
cut_ads  # used dynamically by ads_module.cut_ads in Producer/Workers/wilted_worker/ad_removal.py (src/wilted/ads.py:1491)
detect_ads  # used dynamically by ads_module.detect_ads in Producer/Workers/wilted_worker (nomination, commercial_recovery) (src/wilted/ads.py:1009)
display_feed_reference  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/feed_refs.py:67)
evict_stt_model  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/transcribe.py:466)
execution_capability_scope  # used dynamically by Producer/Workers/wilted_pipeline.py and ad_corpus.py (src/wilted/execution_capability.py:53)
extract_title_from_paste  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/text.py:25)
generate_article_cache  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/cache.py:141)
get_transcript  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/transcribe.py:646)
is_paragraph_cached  # baseline entry kept from the earlier allowlist (callers were in the retired Python app) (src/wilted/cache.py:100)
load_audio  # baseline entry kept from the earlier allowlist (callers were in the retired Python app) (src/wilted/cache.py:50)
load_transcript  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/transcribe.py:761)
make_bws_enclosure_reference  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/feed_refs.py:73)
make_bws_guid  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/feed_refs.py:82)
remove_promos_batch  # baseline entry kept from the earlier allowlist (callers were in the retired Python app) (src/wilted/ads.py:1693)
resolve_enclosure_url  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/feed_refs.py:121)
save_transcript  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/transcribe.py:733)
segments_to_text  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/transcribe.py:805)
split_into_chunks  # callers retired with the Python app; retained with its tests until a follow-up prune (src/wilted/text.py:43)
transcribe_audio  # used dynamically by transcribe.transcribe_audio in Producer/Workers/wilted_worker/transcript_sources.py (src/wilted/transcribe.py:530)
