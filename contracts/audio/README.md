# Audio budget evidence

`evidence/2026-08-17-audio-budget-sizing.json` is the exact JSON stdout from a
fresh `audio-contract-probe --sizing` run for 5, 30, and 90 minutes (the probe
was retired on 2026-10-19; it stays in git history). It records
the measured hashes, durations, encoded bytes, 90-minute measurement, and the
configured 96 kbps reference used to derive the app-owned 80,000,000-byte
per-revision policy.

`publication-budget.json` records the app-owned audio publication budget policy
(`maxRevisionAssetBytes` and `maxOwnedAssetBytes`).

Validate the evidence against the publication budget policy with:

```sh
bash tests/test-audio-budget-evidence.sh
```

The validator recomputes the rounding formula, cross-checks
`maxRevisionAssetBytes`, and requires the 800,000,000-byte aggregate to equal
10 times the per-revision app-owned policy. These are app policy values, not
CloudKit service limits.
