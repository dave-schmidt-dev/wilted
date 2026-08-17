# Article Extraction Probe

This dependency-free macOS 14 Swift package is a falsifiable native static-extraction candidate, not the production extractor. It validates strict HTTP(S) request input, UTF-8 decoding, title/metadata/canonical discovery, simple `main`/`article`/`body` text selection, explicit outcomes, live status events, and cooperative cancellation. It never executes JavaScript or performs network access.

Controlled outcomes use bounded static evidence rather than fixture-only oracle markers: an empty `app`/`root` container plus script and no visible body is script-only; privacy language plus dialog structure and choice buttons is a consent wall; subscription language plus a short structurally identified subscription/paywall shell is headline-only. These deliberately narrow heuristics may reject unsupported pages and do not claim general publisher compatibility.

`Fixtures/manifest.json` defines exactly ten local cases. Every page is synthetic MIT-licensed text authored for this probe, contains no copied publisher prose, and is bound to the manifest by SHA-256. Intentional malformed markup, declared UTF-8, consent, paywall, script-only, and empty states are recorded rather than inferred from a drifting live site.

Run:

```sh
swift test --package-path Probes/ArticleExtractionProbe
bash tests/test-article-extraction-probe.sh
swift run --package-path Probes/ArticleExtractionProbe article-extraction-probe --fixtures Probes/ArticleExtractionProbe/Fixtures
```

The CLI emits per-stage progress to stderr and one final JSON summary to stdout. The evidence is deterministic fixture coverage, hash/provenance integrity, expected outcome/content matching, URL fail-fast behavior, cancellation observability, and fail-closed manifest decoding.

The native-versus-separately-packaged-helper comparison remains open. This probe establishes only the native candidate's static-HTML baseline and controlled unsupported boundary; helper packaging, parser breadth, and any third-party or WebKit choice remain owner-gated Phase 0 decisions.
