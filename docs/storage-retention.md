# Wilted storage retention

`scripts/storage-retention.py` is the policy owner. It is a dry run unless
`--apply` is supplied, accepts `--budget-seconds` (the scheduled job uses the
300-second default), and records weekly due state under the reserved
`.logs/retention-due.json`. The LaunchAgent installer is idempotent; its
`RunAtLoad` entry invokes `/bin/bash scripts/run-storage-retention.sh`, which
then invokes `/usr/bin/python3`. Due state prevents login-triggered repeats.

The policy never sweeps source, `.git`, media, feedback originals, README /
INVARIANTS / TASKS evidence, pinned evidence, or reserved retention outputs.
Evidence is archived into a verified compressed archive before deletion.
Archives contain a manifest mapping original paths to SHA-256 content members;
duplicate bytes are stored once. A failed archive, changed identity, symlink,
mount boundary, busy lock, unreadable result, or uncertain liveness skips the
item.

## Policy

| Category | Retention |
| --- | --- |
| Development logs and source snapshots | After 14 quiet days, preserve verified compressed recovery material before removing raw copies. |
| Test results | After 14 quiet days, keep summaries, full test trees and all failure attachments; retain unreadable or unknown bundles. |
| System log archives | Replace only after successful Wilted-filtered export. |
| Build caches | Whole-unit least-recently-used eviction toward 4 GiB, only after 24 idle hours and all shared locks/liveness checks. |
| Automatic migration backups | Keep newest three and every copy younger than 30 days; retained copies must pass integrity checks. |
| Manual/recovery backups, library, media and original feedback | Never swept. |
| Current ad investigations and cited evidence | Pinned in place, regardless of age. |
| Recovery packs and audit maps | Protected from later compaction. |

The schedule runs locally once a week and checks on login without repeating a
successful run within seven days. It has a five-minute work budget, prevents
self-overlap, and writes a terminal receipt under `.logs/retention-runs`.
A busy or uncertain item is reported and left in place; the 4-GiB target is not
an unconditional disk quota. Cache removal can make the next build slower.

## Shared executor API

`scripts/retention/core.py` is the safety API for the manifest executor:
`ensure_safe_path(root, candidate)` enforces containment, rejects symlinks and
device changes; `identity(path, root=...)` returns immutable size, mtime,
device, and SHA-256 identity; `archive_paths(paths, root, destination)` creates
and verifies an atomic deduplicated `content.zip` plus `manifest.json`;
`verify_archive(destination)` verifies CRCs and every recorded content hash; and
`delete_verified(path, expected_identity, root=...)` rechecks identity and
containment immediately before unlinking. Evidence and backup removal use the tree manifest/digest primitives. Cache
eviction has a separate verified remover for opaque internal links; it uses
platform-safe recursive deletion only after lock and snapshot checks. Callers
must not add ad hoc recursive removal.
`restore_archive(archive, destination)` verifies first and restores only
manifest paths and hash-checked bytes into a new tree.

Build caches are evicted as whole units only after 24 quiet hours, while their
existing advisory lock is held; lock files, lock namespaces, unknown roots,
active processes, mount boundaries and linked roots remain untouched. Cache payloads may contain ordinary internal framework/debug links: these are inventoried as opaque links and never followed; a target outside the same cache unit prevents eviction. Evidence and backup trees reject links entirely. Automatic
SQLite backups are recognized only by the versioned UUID directory form,
retain newest three and all younger than 30 days, and require read-only
`quick_check`. Manual, preimport, recovery, unknown, live database/WAL/media
paths are preserved.

## November 4 explicit disposal

The owner subsequently directed deletion of all 79 bundles that the initial
audit retained for missing metadata or unknown outcomes. They were removed
without a new archive. The current disposition is recorded in
`.logs/retention-reassessment-2026-11-04/removal-receipt.json`; original cleanup
receipts describe the earlier preservation, not current availability. The
weekly policy for future unknown results remains unchanged.

## Recovery

For new weekly archives, restore into a new directory:

```sh
python3 scripts/storage-retention.py --restore ARCHIVE_DIRECTORY NEW_DIRECTORY
```

For a large restore, add `--budget-seconds 3600`. Interactive recovery accepts
up to 24 hours; scheduled maintenance remains capped at five minutes.

When that restored archive contains a source-member export, rebuild its original
file names with `python3 scripts/storage-retention.py --restore-snapshot EXPORT_DIRECTORY NEW_SOURCE_DIRECTORY`. The export keeps member bytes and a reconstruction map; it does not recreate the original compressed container byte for byte.

For the November 4 audit, the original relative path is the lookup key:

```sh
python3 scripts/retention/manifest_recovery.py restore-path --source-path ORIGINAL_PATH --destination NEW_FILE
python3 scripts/retention/manifest_recovery.py restore-archive --source-archive ORIGINAL_ARCHIVE_PATH --destination NEW_DIRECTORY
```

The archive command reconstructs source members as a directory tree. It does
not promise a byte-identical ZIP/TAR container. Intentional disposal rows,
such as obsolete whole-device captures, have no recovery copy. Keep the audit
maps and their protected content packs together; the Git recovery pack is
self-contained and does not depend on a branch or reflog remaining available.

The tracked `scripts/retention/apply_manifest.py` executor is deliberately bound
to the November 4, 2026 audit. It is not used by the weekly job and does not
authorize a future audit. Open-file checks and identity verification reduce
writer races; they do not impose a global filesystem lock on other programs.
