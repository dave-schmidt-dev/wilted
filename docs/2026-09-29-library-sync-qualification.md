# Library sync qualification (2026-09-29)

Device: iPhone 16 Pro Max (iPhone17,2), Mac dm5mbp (macOS 26.6.2), home Wi-Fi, foreground.
iOS version: 27.0.1 (24A446)
Build: integration branch at 953e53d; Development Mac app launched by `scripts/attended-cloudkit-run.sh --library-sync` (WILTED_LIBRARY_SYNC=1, CloudKit Sandbox); Development iOS app installed on the device by the same run.
Screenshot: none captured; results are David's on-device observations, reported in chat.
Result: PASS for Larder order, removal section, paused position and reorder. NOT YET VERIFIED: retirement propagation.

## Observations (David, attended)

1. Fresh launch: the phone's active Larder list matched the Mac's order.
2. An in-progress episode showed the Mac's last paused position correctly.
3. The removed section (retired and dismissed) was present and looked right on a glance; individual items were not audited row by row.
4. Reorder: an episode reordered on the Mac appeared reordered on the phone within about 5 seconds, foreground.

## Not covered

- Retirement (skip or finish on the Mac) reaching the phone was not exercised in this run.
- No audio moved; Phase 2 exit is state only.
- Background delivery was not tested (spike verdict: fetch on foreground).
