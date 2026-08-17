# Audio contract probe

This dependency-free macOS 14+ Phase 0 probe tests one transfer-file candidate: a single gapless M4A container carrying mono AAC at 44.1 kHz and 96 kbps. It generates deterministic speech-like PCM locally, encodes it with AVFoundation, validates the decoded format and duration, seeks near the beginning/middle/end, closes and reopens after an interruption, measures first-byte-to-play decode latency, hashes the durable file, and publishes it with a temp-write/flush/close/validate/hash/atomic-rename sequence.

Run:

```sh
swift test --package-path Probes/AudioContractProbe
swift run --package-path Probes/AudioContractProbe audio-contract-probe --output /tmp/wilted-audio-candidate.m4a
swift run --package-path Probes/AudioContractProbe audio-contract-probe --sizing --output-dir /tmp/wilted-audio-sizing
bash tests/test-audio-contract-ios-build.sh
```

`--sizing` encodes deterministic, chunked 5-, 30-, and 90-minute synthetic articles with the same candidate. It reports actual duration, encoded bytes, bytes per minute, the fixed PCM chunk bound, and an app-owned per-revision budget derived from the 90-minute measurement: double that measured size, compare it with the exact 96 kbps reference (64,800,000 bytes for 90 minutes), then round up to the next 10,000,000-byte boundary. This is not a claimed CloudKit limit.

The CLI emits progress stages on stderr and exactly one JSON report on stdout. Reports explicitly label their evidence as macOS-only; iOS/device validation remains unresolved until a signed iOS 17 physical-device playback test.

The iOS build leg uses SwiftPM and the iPhone Simulator SDK to compile the core and XCTest source targets for `arm64-apple-ios17.0-simulator`. It does not run tests, launch a simulator, sign an app, or claim iOS playback/runtime evidence.
