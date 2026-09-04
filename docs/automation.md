# App-open automation

Wilted can refresh subscribed podcast feeds and download newly admitted episodes on its
own, without a listener pressing Refresh or Download. This document describes how that
automation is scheduled, how it claims work so nothing transfers twice, what happens when
it fails, and what it does not yet do.

The relevant source is `WiltedMac/WiltedAutomationCoordinator.swift` (scheduling, claims,
retry, status), the `WiltedAutomationSettings` family near the top of
`WiltedMac/WiltedMacModel.swift` (the persisted policy), and the admission/claim methods in
`Producer/Sources/WiltedProducer/LocalLibraryStore.swift`.

## Why automation only runs while the app is open

Wilted has no background agent, launchd job, or push mechanism. Automation is driven
entirely by two triggers a running app can notice: launch, and a 900-second timer that
only exists while a window is open. A closed app and a sleeping Mac do no work of any
kind — there is nothing running to notice a due refresh.

This is deliberate, not a gap to be closed later. `refreshPolicy`'s `.whileOpen` case is
evaluated against a persisted last-success timestamp rather than a wall-clock schedule: a
refresh becomes due once enough time has passed since the last success, and it is
evaluated the next time one of the two triggers fires, however late that is. A missed
interval — the Mac asleep for a day, or Wilted simply not launched — becomes eligible at
the next open. It is not queued, and it is not made up by running twice or by catching up
several missed intervals at once. The persisted timestamp is what stops an interval tick
from repeating work a launch already did, not a calendar.

## Settings

One versioned, validated, Mac-local value, `WiltedAutomationSettings`, holds every axis.
It is stored through `UserDefaults` (`setAutomationSettings` / `loadAutomationSettings`);
a missing or unparseable value, or one written by a future version, decodes to
`.defaults` rather than failing, so an upgrade or a corrupted preference never blocks the
app.

### Refresh policy (`refreshPolicy`)

- **Manual** (default) — automation never refreshes a feed. Only the listener's own
  Refresh action does.
- **On launch** — every app launch triggers a refresh evaluation. The interval tick never
  refreshes under this policy; only the `.launch` trigger does.
- **While open, every 6, 12, or 24 hours** — the open-window tick (and launch) refreshes
  once the persisted last-success timestamp is at least that old. With no stored
  timestamp yet (first run under this policy), a refresh is immediately due.

### Download policy (`downloadPolicy`)

Automation only ever claims episodes that the triggering refresh itself just admitted —
never the existing back catalogue of a feed. This is a hard limit inside the store, not
just a UI default; see Claims, below.

- **Manual** (default) — a refresh may run, but nothing is downloaded automatically.
- **Newest new episode per enabled feed** — up to 1 newly admitted episode per feed, no
  ceiling across the whole refresh.
- **Newest 3 new episodes per enabled feed** — up to 3 per feed, same lack of a
  refresh-wide ceiling.
- **All newly admitted, up to 20 per refresh** — up to 20 per feed, but also capped at 20
  total across the entire refresh pass. Feeds are processed in a stable order and the
  budget is consumed as it goes, so a feed reached later in the pass can end up claiming
  fewer than 20, or none, if earlier feeds already used the budget.

Manual download from a Larder row remains available under every policy.

### Processing policy (`processingPolicy`) and transcript policy (`transcriptPolicy`)

These exist as settings today — **Immediately after download** (default), **Manual**, or
**Off-peak while open** with a local start/end time for processing; and **Best
available** (default), **Always transcribe**, or **No local STT** for transcript
acquisition, alongside the `removeAds` and `readableTranscriptPass` booleans (both
default on) — and they validate and persist correctly. See Known limits: none of them is
currently read by anything that prepares an episode. Preparation still runs immediately
after every download, manual or automatic, using the preparation pipeline's own built-in
default policy (best-available transcript, ads removed, readable pass on), regardless of
what is configured here.

## Claims: what stops the same episode transferring twice

A "claim" is not a separate table or flag. It is a `PodcastDownload` record with status
`.queued`. Creating that record — by whatever path — is what reserves an episode for
download, because the download coordinator and the preparation pipeline both key off that
same record's existence and status.

For automation, the claim is made in `LocalLibraryStore.admitPodcastEpisodes(_:admission:
claimingNewest:claimedAt:)`, in the *same* `context.save()` that admits the feed's new
episodes. This matters because admitting episodes and then separately enqueuing a claim
in a second save leaves a crash window: if the process dies between the two saves, the
next launch has no way to tell which episodes were newly admitted by that refresh, because
"newly admitted by this admission" is not a fact recorded anywhere except the admission
itself. Doing both in one save means the new episode rows and their claims are either both
durable or neither is — there is no partial state to reconcile.

Within that same call, an episode is only claimed if no `PodcastDownload` record exists
for it at all (any status — queued, downloading, completed, failed, or cancelled all
count as spoken for). This mirrors `claimPodcastDownload`'s `.untouched` scope, used
elsewhere for the same purpose: a settled decision, even a failed one, is the listener's
to revisit, not automation's to redo.

Manual downloads go through `claimPodcastDownload(episodeID:scope:)` instead, using
`.notInFlight` scope: only an in-progress transfer (`.queued` or `.downloading`) blocks a
new claim. This is what lets a listener retry a failed or cancelled download from the row
— the settled record does not block a fresh claim the way it would for automation. Both
scopes exist for the same reason: manual and automatic entry points race (a refresh can
admit an episode the instant before the listener presses Download on it), and the store
actor makes the existence check and the insert one atomic step, so only one caller ever
wins the race and starts the transfer.

Subscribing to a feed for the first time (`.backfill` admission) never claims a download,
whatever limit is passed in. Subscribing to a podcast is not a request to download its
back catalogue, so the store refuses to let a caller turn it into one by passing a
nonzero limit.

## What happens on relaunch

A claim (a `.queued` or `.downloading` `PodcastDownload` record) is durable, but a running
transfer is not — if Wilted's process dies mid-download, the record survives with no
transfer behind it. `LocalLibraryStore.unfinishedPodcastDownloads()` is how a fresh launch
finds those records; it is the only source of truth for which episodes are in that state,
since automation keeps no separate bookkeeping of its own.

On launch, `WiltedMacModel.startAutomationOnLaunch()` calls the coordinator's
`reconcile()` before it evaluates the launch trigger's own refresh-and-download pass.
Both go through the same single-pass slot on the coordinator actor (`run` and `reconcile`
both check and set the same `running` task), so they run strictly in sequence rather than
racing each other for the same claims.

Automation is started from the transition to a ready surface, after the library is in
memory, precisely so reconciliation can resolve a claimed episode ID against the loaded
episodes. If it nonetheless finds a claim with no episode behind it, the model raises
`WiltedAutomationFault.claimedEpisodeMissing` rather than returning quietly. That
distinction is the point: a silent return would count the claim as downloaded and clear
work no transfer ever performed. The raised fault leaves the `.queued` record in place for
a later launch to retry.

Reconciliation only runs at launch. It does not run on the periodic open-window tick, so
a claim from a pass earlier in the same session that is still outstanding waits for the
next relaunch, not the next tick, before it is revisited.

## Failure and retry

Both of the coordinator's network-facing operations — refreshing a feed and starting a
download — go through the same bounded exponential backoff (`withRetries`, in
`WiltedAutomationCoordinator`): up to 3 retries, with each wait doubling from a 2-second
base (2s, 4s, 8s). The bound exists because an automatic loop that never gives up is a way
to hammer a feed host from a machine nobody is watching. Cancellation is rethrown
immediately rather than treated as a retryable failure, so stopping automation does not
wait out an in-progress backoff first.

One feed being unreachable does not abandon the rest of the refresh pass. Each feed's
refresh is retried on its own; if it still fails after exhausting retries, the pass
continues to the next feed rather than stopping the whole run. The refresh's last-success
timestamp only advances if at least one feed refreshed successfully (`refreshed > 0`).
Two consequences follow from that: a refresh where every feed failed leaves the timestamp
untouched, so the whole refresh stays immediately eligible at the next trigger rather than
being considered "done" for the interval; and a refresh where some feeds succeeded still
advances the timestamp for the whole pass, so one persistently broken feed sitting among
otherwise-healthy ones is not retried again until the next full interval elapses, not
sooner.

A download that starts and then genuinely fails (a network error mid-transfer, for
example) settles to a terminal `.failed` `PodcastDownload` record, the same way a manual
download failure does. That record is not `.queued` or `.downloading`, so it is outside
what `unfinishedPodcastDownloads()` returns and relaunch reconciliation does not touch it;
retrying it is a manual action from the Larder row, exactly as it is for a failure that
originated from a manual download.

Status through a pass — `idle`, `refreshing(feedsRemaining:)`,
`downloading(episode:remaining:)`, `retrying(afterSeconds:attempt:)`, `failed`,
`cancelled`, `finished(refreshed:downloaded:)` — is reported live so a listening surface
can show progress and a working cancel action rather than going quiet for the minutes a
refresh-and-download pass can take. On failure, the surface is told only that "Automatic
updates could not finish. They will try again," deliberately without the underlying cause
— the cause belongs in the log and in Prep's preparation journal, not in a banner the
listener cannot act on directly.

## Known limits

- **Backfill admission never claims a download**, regardless of the limit a caller passes.
  Subscribing to a feed is intake, not a standing request to download its catalogue.
- **The default policy is all-manual.** `refreshPolicy` defaults to `.manual`, so
  automation performs no action of any kind — no refresh, no download — until a listener
  changes it. Absent any configuration, this feature is inert.
- **`processingPolicy` and `transcriptPolicy` (and `removeAds` /
  `readableTranscriptPass`) are stored and validated but not yet wired to anything.**
  Every preparation, automatic or manual, still runs immediately after download using the
  preparation pipeline's own fixed default policy. Configuring an off-peak processing
  window or a different transcript policy currently has no observable effect.
- **There is currently no in-app control surface for these settings.** They are only
  reachable through `WiltedMacModel.setAutomationSettings(_:)`; nothing in the Mac UI
  presents Feeds, Downloads, or Processing controls yet.
- **A download that fails after it starts requires a manual retry.** It settles to
  `.failed`, which is a decision reconciliation treats as already made, not an unfinished
  claim to resume.
- **Automation is Mac-local.** Settings live in `UserDefaults` on the Mac; there is no
  CloudKit sync of preferences and no background agent. Automation only ever runs inside
  a foreground, currently-open Wilted process on the machine where it was configured.
