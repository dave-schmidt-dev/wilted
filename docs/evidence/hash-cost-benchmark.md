# Full-file hash cost benchmark

- date: 2026-09-15
- device/OS: MacBook Pro (Mac17,6), Apple M5 Max, macOS 26.6.2 (25G83), arm64
- command: `swift test --package-path Listener --filter fullFileHashCostBenchmark`
- hash algorithm: SHA-256
- revision count: 4
- fixture bytes: 4,194,304 bytes per revision; 16,777,216 bytes total
- measured duration: 6.000 ms for four cached full-file validations
- fixture: deterministic in-memory bytes with one distinct repeated byte value per revision, written through `ListenerAudioCache` before validation
- proposed threshold: 100 ms for this exact 16 MiB fixture
- owner decision: accepted 100 ms threshold on 2026-09-15
- optimizationNeeded: false

The benchmark is deliberately synthetic and makes no claim that it represents a typical
episode. It establishes a reproducible local baseline for the existing full-file
validation path. The measured result is below the accepted 100 ms threshold for this
exact 16 MiB fixture. No size-plus-mtime shortcut is included; a future over-threshold
measurement can reopen that optimization decision.
