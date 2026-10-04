# Store migration (V14 statistics, V15 links, V16 automation): backup, validation, restore, downgrade refusal

Store schema V14 adds the measured lifetime ledger (`LifetimeMeasureEventRecord`),
its per-session/attempt high-water rows (`LifetimeMeasureHighWaterRecord`), one
rebuildable summary row (`LifetimeStatisticsSummaryRecord`) and the write-once
tracking-start row (`LifetimeStatisticsTrackingRecord`). No existing table
changes shape; the V13 -> V14 stage is lightweight. The code is in
`Producer/Sources/WiltedProducer/LocalLibrary/LocalLibraryStore+Bootstrap.swift`
and `LocalLibraryStore+Migration.swift`.

Store schema V15 adds one table, `PodcastEpisodeLinkRecord` (unique `itemID`,
`url`, `updatedAt`): an episode's own web page, from the feed item's `<link>`.
It sits beside the unchanged V13 episode record, so the V14 -> V15 stage is
lightweight and no existing record changes shape. A refresh writes, changes or
removes the row to mirror the feed; dismissal keeps it with the episode row;
unsubscribing deletes it. A migrated store starts with the table empty and
fills it on the next refresh. The V15 stage goes through the same sequence
below, so a V14 store gets the same clone check, retained backup and
restore-on-failure as a V13 one. The code is in `LocalLibrarySchemaV15.swift`
and `LocalLibraryStore+EpisodeLinks.swift`.

Store schema V16 adds three wholly new tables: `PodcastFeedPolicyRecord`
(per-feed automation overrides), `EpisodeMatchRuleRecord` (ordered per-feed
matching rules), and `EpisodeDecisionRecord` (one keep/skip decision per
episode). No existing entity changes shape, so V15 -> V16 is lightweight.

Never practise this procedure on the owner's library. Use a copy of
`Producer/Tests/Fixtures/library-v13.store` or `library-v14.store` under a
`mktemp -d` directory below `$TMPDIR`.

## What happens on open

`LocalLibraryStore(url:)` runs one sequence for every build configuration:

1. **No file:** a new V16 store is created. Its summary starts `ready` at zero,
   and tracking starts now.
2. **Version detection:** the store's entity version hashes are read from its
   metadata through a read-only Core Data call. They are compared with every
   released schema, V1 through V16. Nothing is written.
3. **Unrecognised or newer store:** the open throws
   `LocalLibraryStoreError.incompatibleStoreVersion`. This is the downgrade
   refusal. It happens before any checkpoint, copy or open, so the main file,
   `-wal` and `-shm` stay byte-identical and no backup directory is created.
4. **Current V16 store:** it opens directly.
5. **Older store (V1 to V15):**
   1. `PRAGMA wal_checkpoint(TRUNCATE)` folds the WAL into the main file. A busy
      or incomplete checkpoint aborts the open.
   2. Entity-table row counts are read through a read-only SQLite connection.
   3. A **disposable clone** of the main file is migrated to V16 with the full
      migration plan and reopened. Its row counts must equal the source's for
      every table both have. The clone is then deleted.
   4. The checkpointed main file and **every** sidecar are copied to the
      **retained backup**. By default that is
      `<store>.v<N>-backup-<UUID>/<store>`, next to the store.
   5. The store is migrated in place, and its row counts are verified again.
   6. On any failure in steps 5.3 to 5.5, the original is restored from the
      backup and the open throws `migrationFailedRestored(backupURL:reason:)`.
      If the restore itself fails, the open throws
      `migrationRestoreFailed(backupURL:reason:)`, and the backup is left intact
      for the manual restore below.
6. **Statistics rows:** the tracking-start row is written once, at the first
   V14 open, and is never updated. A migrated store whose ledger already has
   rows opens with the summary in `rebuildRequired`.

`LocalLibraryStore(url:migrate: false)` never migrates. A store that needs a
migration throws `migrationRequired(fromVersion:)` and is left untouched.

Backups are never deleted automatically. The store reports the backup made
during this open in `LocalLibraryStore.migrationBackupURL`.

## Summary rebuild is not part of opening

Opening never rebuilds the summary. Before the rebuild:

- `lifetimeStatisticsSummary()` returns `state == .rebuildRequired` with zero
  totals and the tracking start.
- `lifetimeStatistics()` still returns the correct four legacy totals by reading
  the legacy ledger.

Run `rebuildLifetimeStatisticsSummary(batchSize:progress:)` in the background:

- It pages the measured ledger by sequence, reports progress for each page, and
  stops at the next page boundary when cancelled.
- It then reads the legacy ledger and publishes both totals in one save.
- A cancelled or failed rebuild leaves the stored summary unchanged.
- It is safe to run again at any time.

## Manual restore (operator)

Use this when an open threw `migrationRestoreFailed`, or when you deliberately
roll a migrated store back.

1. Quit Wilted. Confirm that nothing has the store open:
   `lsof <store>` should print nothing.
2. Find the backup directory, `<store>.v<N>-backup-<UUID>/`. If more than one
   exists, use the newest one for the version you want.
3. Move the current `<store>`, `<store>-wal` and `<store>-shm` aside. Do not
   delete them.
4. Copy the backup's `<store>` and each `<store>-*` sidecar into the store
   directory under the original names.
5. Check the restore with `sqlite3 -readonly <store> 'PRAGMA integrity_check;'`.
   It must print `ok`.

The same procedure is executable from code as
`LocalLibraryStore.restoreMigrationBackup(_:)`. It removes the source files
before copying the backup to new files, so a stale connection cannot write into
the restored copy. Tests run it on fixtures:

- `testRetainedBackupRestoreProcedureReturnsTheV13Store`
- `testFailureAfterInPlaceMigrationRestoresTheV13Original`

## Downgrade

An older build cannot open a V16 store, because its migration plan has no V16
schema. This build refuses anything newer than V16 the same way, without
writing to it. To run an
older build, restore that version's retained backup using the steps above.
Measured events and episode links recorded after the migration are not in that
backup and are lost on downgrade.

## Evidence

All of these are in `Producer/Tests/WiltedProducerTests/`.

- `LocalLibraryEpisodeLinkTests` covers:
  - the frozen V14 fixture hash
  - V14 to V16 migration keeping every table's row count and every statistic
  - injected post-migration failure restoring the V14 original
  - refusal of a store newer than V16 with a byte-identical directory
  - the link written by admission and refresh, joined by the snapshot, kept on
    dismissal and deleted with the episode
- `LocalLibraryStoreCompatibilityTests` covers:
  - the frozen V13 fixture hash
  - V13 to V16 migration and reopen with every fixture value preserved
  - backup bytes equal to the fixture
  - `migrate: false` refusal
  - injected post-migration failure and restore
  - a hot-WAL V13 source checkpointed into a complete backup
  - refusal of a newer store with a byte-identical directory
- `LocalLibraryFeedAutomationTests` covers the frozen V15 fixture and V13,
  V14 and V15 migration to V16 with retained backups and preserved rows.
- `LocalLibraryLifetimeEventTests` covers:
  - units
  - exact-key deduplication
  - high-water checkpoints
  - progress and cancellation of the rebuild
  - writes committed during a rebuild, counted exactly once
  - two store instances on one file never overwriting each other's events
  - flat exact-key costs on a large ledger under concurrent writers
