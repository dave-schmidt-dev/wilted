# Transport spike evidence (2026-09-29)

Device: iPhone 16 Pro Max (iPhone17,2), Mac dm5mbp (macOS 26.6.2), home Wi-Fi, both foreground unless stated.
iOS version: 27.0.1 (24A446)
Peak quota: not measured directly (no quota API used). Bytes written per strategy per full run set: 610 MB (3 x 20, 60, 120 MB plus one 250 MB). Teardown removed the spike zone, subscriptions and iCloud Drive files on both devices.
Verdict: use CloudKit for small state; move audio on demand as a single CKAsset record (own record type, fetched by raw operations with `desiredKeys`), not chunked. Fetch handoff state on foreground; do not rely on background delivery.

Raw data: phone report `spike-report-iPhone-2026-09-29T13-49-29Z.json` (two runs appended: run 1 CloudKit assets rejected, run 2 succeeded), Mac report `spike-report-dm5mbp-2026-09-29T13-50-02Z.json` (run 1 only).

## Transfers (phone, upload wall seconds; MB/s from the median)

Run 1 rejected every CloudKit asset upload on both devices with `Invalid bundle ID for container` (10/2007). Record saves worked. Run 2, about 30 minutes later with no change, succeeded, so this looks like propagation delay after automatic App ID registration. Cause unconfirmed.

- cloudkit-single-asset upload: 20 MB 8.6 to 11.7 s, 60 MB 21.5 to 24.8 s, 120 MB 46.8 to 51.9 s, 250 MB 98.7 s (about 2.5 MB/s). No size cap hit at 250 MB.
- cloudkit-chunked-asset-45mb upload: 20 MB 11.2 to 12.4 s, 60 MB 18.3 to 28.2 s, 120 MB 50.1 to 56.3 s, 250 MB 109.2 s (about 2.3 MB/s). About 10 percent slower than a single asset, no benefit.
- cloudkit-chunked-asset-45mb download: 20 MB 2.7 to 4.6 s, 60 MB 7.9 to 11.5 s, 120 MB 19.4 to 29.4 s, 250 MB 68.8 s (about 3.6 MB/s).
- cloudkit-single-asset download: 0.4 to 1.1 s at every size including 250 MB. That is not plausible network speed (same device just uploaded it), so treat as a local cache hit; a true cross-device download time is still unmeasured.
- icloud-drive-ubiquity upload: 20 MB 8.9 to 32.5 s, 60 MB 25.7 to 49.9 s, 120 MB 41.8 to 96.7 s, 250 MB 96.0 to 148.1 s (about 1.7 to 2.6 MB/s, high variance). Mac: 20 MB 6.8 to 8.9 s, 60 MB 33.3 to 50.2 s, 120 MB 81.7 to 101.0 s, 250 MB 147.7 s. Download times are about 0 s (same device, meaningless); iCloud Drive gives no progress callbacks and needs the extra ubiquity capability.

## Eager fetch under CKSyncEngine

Per-question verdict: confirmed eager.

Confirmed: `CKSyncEngine` delivered the record with the asset file already on disk (`syncEngineAssetFileExistsAtFetch: true`, 20971520 bytes, 1.34 s). A raw `CKFetchRecordsOperation` with `desiredKeys` omitting the asset returned no asset field (0.15 s); a full raw fetch took 0.36 s. Audio therefore must live in its own record type outside the sync engine's zone, fetched with raw operations, as the plan designed.

## Handoff propagation (Mac publisher, 5 s cadence, phone observer)

Per-question verdict: foreground handoff meets the goal; background handoff does not.

- Foreground: 41 updates received; publish to receive latency min 0.76 s, median 1.12 s, p90 1.61 s, max 3.53 s.
- Backgrounded: no update for 490 s (sequence 38 to 118), then caught up on return to the foreground. Background delivery was not dependable in this run; only one background period was tested, so whether silent push was delivered at all is not established.
- Clock offset (publisher versus server modification date): Mac median 0.48 s, min 0.42 s, max 1.38 s over 122 samples.

## Teardown

Phone: zoneDeleted true, ubiquityDirectoryRemoved true. Mac: zoneDeleted true, ubiquityDirectoryRemoved true, subscription `SpikeSubscription-handoff-database` deleted. The run 2 records were created after the run 1 teardown; a second teardown was not run after run 2 (report notes list only the first), so `SpikeZone` may still hold run 2 data (about 610 MB x 2 CloudKit strategies). Delete it via the spike app's Teardown before leaving the spike installed.
