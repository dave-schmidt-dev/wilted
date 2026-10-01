# Sync cadence: one 30 s tick per device

**Rule.** Each device has ONE sync tick (`SyncTick`, `SyncCadence.tickInterval` = 30 s) and everything periodic batches into it: reads, publishes, position checkpoints, the intent index, pending-decision checks. Nothing runs faster. Local position checkpoints stay local and go up at the next round.

- A **user action** (a decision, a media request, a play start, a seek, a pause) may send its write at once as a single operation. Any read that confirms it waits for the next round.
- After a **rate limit** (CKError 7/6) the whole tick backs off by the server's Retry-After, shared by every operation through `TransportGate`. The first round after the wait is the probe.
- **Pull to refresh** runs a full round now and restarts the timer. While the gate is closed it sends nothing and the existing retry banner shows. Pulls made while a round runs join it.
- A silent push or the app coming forward runs a round only if one is due; the timer round covers it otherwise.
- A record known to be missing (the Mac's own `intentindex:mac-…`) is created once or skipped, never refetched.

Pinned in tests: `SyncTickTests` (WiltedKit), `LibraryPollRequestCountTests` (CloudSync), `WiltedMacSyncRoundTests`, `LibraryPhoneSyncTickTests`, `SyncCadenceTests`.

## What a round holds

| | Mac (runs while the app runs) | Phone (runs while in front or playing) |
|---|---|---|
| Read | `poll([.intents, .deviceRecords])`: one `fetch-records` for the intent indexes and the phone's playback records; stage 2 only for records that changed | `poll([.deviceRecords, .offers] + .outcomes while a decision waits)`: one request when nothing changed |
| Write | library state and statistics when changed; the playing checkpoint (NowPlaying + Progress as one write); stored positions every 2nd round | the playing checkpoint; positions saved offline |
| State fetch | CKSyncEngine, on its own push | every 10th round, and at once on a foreground, push, pull, or while a decision waits |
| Scan | throwaway engine every 4 rounds while no peer is known, every 40 once one is | none |
| Handoff | decides from the round's own records | decides from the round's own records (no separate observe loop, no confirming fetch after a takeover) |

## Request-rate audit (Mac)

**Before (measured).** `/usr/bin/log show` of the Development Mac (pid 76289, sync on, idle, nothing playing), 2026-10-01 17:00–17:40, 39.9 min, counting `(CloudKit) client/<op>` lines (`scripts/sync-ops-rate.sh --file … 39.85`):

| operation | count | per min |
|---|---|---|
| fetch-records | 363 | 9.11 |
| fetch-record-changes | 95 | 2.38 |
| modify-records | 81 | 2.03 |
| nine engine-setup operations (zones, subscriptions, account, …) | 19 each | 0.48 each |
| **total** | **691** | **17.3** |

The loops behind it: the 30 s inbound poller (intent list, device records, offer reads, a refetch of the missing own intent index every cycle: 228 `intentindex:mac-…` misses in the capture), the publisher's own intent relay and retry timers, the handoff publisher and the stored-position refresh, the statistics write on every listening-clock change, and a throwaway scan engine every 4th poll (19 engines, nine setup operations each, about 4.3 per minute on their own).

**After (modeled by tests, to be measured on the installed build).** An idle Mac round is one operation (`LibraryPollRequestCountTests`: ten idle rounds, ten operations; `WiltedMacSyncRoundTests`: ten idle minutes, 21 reads, at most 2.1 per minute, nothing else touching the server). Add the scan: every 20 min once the phone has been seen (about 0.45 per minute), every 2 min before that. So the idle Mac is about 2 to 2.5 operations per minute, down from 17.

## Request-rate audit (phone)

**Before (modeled from the code, not measured).** Each refresh was `fetchChanges` + device records + offers (+ outcomes while a decision waited) = 3 to 5 requests, run on launch, foreground, pull, push, a 5 s poll while a decision was unsettled (30 s once all were pending), a 2 s poll for an awaited offer, a 30 s observe fetch and a 30 s publish while playing, and a confirming fetch after each takeover.

**After (modeled by `LibraryPhoneSyncTickTests`).** Idle in front: one read per round plus a state fetch every 10th round, about 2.3 operations per minute (20 reads and three state-fetch requests in ten minutes); backgrounded and not playing: none. A decision sends once and is confirmed by the next round. Playing: the round's read and the checkpoint write.

## Measuring on a device

```bash
scripts/sync-ops-rate.sh <pid> 10
```

prints operations per minute by kind from the unified log. The Mac also logs one line per round (`Sync round N: intents n, scan yes/no, ok/failed`, subsystem `com.zerodelta.wilted`).
