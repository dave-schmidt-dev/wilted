# Phase 0 Decision Record

Date: 2026-08-17
Status: verified for native project scaffolding

## Frozen decisions

- **Platforms:** macOS 14+ producer and iOS 17+ iPhone listener.
- **Shared boundary:** a CloudKit-free Swift package (`WiltedKit`) owns identifiers, Codable/Sendable values, merge rules, and fixtures. Platform adapters own persistence, CloudKit, audio, and UI.
- **Persistence:** SwiftData is the initial platform adapter with explicit schema versioning, migration, crash recovery, and persisted CKSyncEngine state. Automatic SwiftData CloudKit mirroring is excluded.
- **Speech:** protocol version 2 over the existing direct Unix socket boundary. The signed-runtime probe supports the current non-sandbox path; socket relocation remains required if App Sandbox is later selected.
- **Extraction:** the native static HTML extractor is the selected MVP boundary. It is intentionally credential-free and does not promise JavaScript execution. Unsupported or blocked pages produce controlled outcomes.
- **Audio:** one gapless M4A/AAC file per immutable revision, mono, 44.1 kHz, nominal 96 kbps, validated and hashed before publication.
- **Budgets:** 80,000,000 bytes per revision and 800,000,000 bytes for the Wilted-owned aggregate publication budget. These are app policy thresholds, not CloudKit service limits. Explicit deletion and **Remove Download** remain the recovery controls.
- **Mac distribution hypothesis:** hardened, notarized Developer ID without App Sandbox for the personal MVP. This is a distribution hypothesis, not signed Production or notarization evidence.

## Evidence completed

The Phase 0 gate exercises domain/cloud contracts, speech IPC and signed-runtime behavior, extraction corpus outcomes, persistence migration/recovery, audio assembly and sizing, and the credential-free Apple capability inventory. Fixtures and validators are checked in under `contracts/`, probes under `Probes/`, and runners under `tests/`.

## Unresolved attended gates

No Apple portal or external state was changed. Before release qualification, the owner must still verify final bundle/team/container identifiers, Development versus Production CloudKit entitlements, schema/index promotion, certificates and profiles, remote-notification/background-audio capabilities, the Developer ID/App Sandbox choice, signed/notarized Mac behavior, physical iPhone playback/background/lock-screen behavior, Production CloudKit delivery, App Store Connect processing, and user-visible internal TestFlight availability. Simulator or Development evidence cannot substitute for those gates.

Invariants: W-INV-001, W-INV-002, W-INV-003, W-INV-004, W-INV-006, W-INV-007, W-INV-008, W-INV-009.
