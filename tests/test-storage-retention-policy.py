#!/usr/bin/env python3
"""Fixture regressions for retention identity, selection and deletion safety."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from retention import backups, caches, core, evidence
from retention.core import (ArchiveError, archive_paths, ensure_safe_path,
                            remove_tree_verified, restore_archive, snapshot_tree,
                            verify_archive)


def old(path: Path, days: float = 15) -> None:
    stamp = time.time() - days * 86400
    os.utime(path, (stamp, stamp), follow_symlinks=False)


def expect_archive_error(callable_object, message: str) -> None:
    try:
        callable_object()
    except ArchiveError:
        return
    raise AssertionError(message)


def test_core(scratch: Path) -> None:
    root = scratch / "repo"
    root.mkdir()
    source = root / "old.log"
    source.write_bytes(b"same")
    duplicate = root / "duplicate.log"
    duplicate.write_bytes(b"same")
    archive = root / ".logs/retained-evidence/archive"
    manifest = archive_paths([source, duplicate], root, archive)
    assert manifest["unique_bytes"] == 4
    assert len(manifest["files"]) == 2
    assert verify_archive(archive)["files"][0]["sha256"]
    restored = scratch / "restored"
    restore_archive(archive, restored)
    assert (restored / "old.log").read_bytes() == b"same"
    assert (restored / "duplicate.log").read_bytes() == b"same"

    # Tree snapshots hash each file once and bind that digest to inventoried metadata.
    inventory_tree = root / "inventory-tree"
    inventory_tree.mkdir()
    inventoried_file = inventory_tree / "data.bin"
    inventoried_file.write_bytes(b"before")
    real_file_identity = core._file_identity
    calls: list[Path] = []

    def count_file_identity(path: Path, deadline=None):
        calls.append(path)
        return real_file_identity(path, deadline)

    with mock.patch("retention.core._file_identity", side_effect=count_file_identity):
        snapshot_tree(inventory_tree)
    assert calls == [inventoried_file]

    real_tree_entries = core._tree_entries

    def mutate_after_inventory(path: Path, deadline=None):
        entries = real_tree_entries(path, deadline)
        inventoried_file.write_bytes(b"after")
        return entries

    with mock.patch("retention.core._tree_entries", side_effect=mutate_after_inventory):
        expect_archive_error(lambda: snapshot_tree(inventory_tree),
                             "tree snapshot accepted a file changed after inventory")

    tree = root / "bundle.xcresult"
    (tree / "nested/empty").mkdir(parents=True)
    (tree / "nested/output.txt").write_text("result")
    def fail_walk(_path, *, topdown, onerror, followlinks):
        onerror(PermissionError("injected unreadable directory"))
        return iter(())
    with mock.patch("retention.core.os.walk", side_effect=fail_walk):
        expect_archive_error(lambda: snapshot_tree(tree), "incomplete unreadable tree accepted")
    tree_archive = root / ".logs/retained-evidence/tree"
    archive_paths([tree], root, tree_archive)
    tree_restored = scratch / "tree-restored"
    restore_archive(tree_archive, tree_restored)
    assert (tree_restored / "bundle.xcresult/nested/output.txt").read_text() == "result"
    assert (tree_restored / "bundle.xcresult/nested/empty").is_dir()

    broken = json.loads((archive / "manifest.json").read_text())
    broken["files"][0]["sha256"] = "0" * 64
    (archive / "manifest.json").write_text(json.dumps(broken), encoding="utf-8")
    expect_archive_error(lambda: verify_archive(archive), "archive accepted bad member hash")

    outside = scratch / "outside"
    outside.write_text("untouched")
    expect_archive_error(lambda: ensure_safe_path(root, root / ".." / "outside"),
                         "parent-component escape accepted")
    link = root / "linked"
    link.symlink_to(outside)
    expect_archive_error(lambda: ensure_safe_path(root, link), "symlink source accepted")
    expect_archive_error(lambda: ensure_safe_path(root, link / "child"),
                         "symlink ancestor accepted")

    target = root / "delete.log"
    target.write_text("first")
    expected = snapshot_tree(target, root=root)
    target.write_text("changed")
    expect_archive_error(lambda: remove_tree_verified(target, expected, root=root),
                         "stale source snapshot removed")
    assert target.read_text() == "changed"
    current = snapshot_tree(target, root=root)
    remove_tree_verified(target, current, root=root)
    assert not target.exists()

    remove_dir = root / "delete-tree"
    (remove_dir / "child").mkdir(parents=True)
    (remove_dir / "child/file").write_text("safe")
    expected_tree = snapshot_tree(remove_dir, root=root)
    remove_tree_verified(remove_dir, expected_tree, root=root)
    assert not remove_dir.exists()

    # The packer must never include its own staging directory in the selected tree.
    conflict = root / "self-containing"
    conflict.mkdir()
    expect_archive_error(lambda: archive_paths([conflict], root, conflict / "archive"),
                         "destination inside source accepted")
    assert outside.read_text() == "untouched"


def test_evidence_policy(scratch: Path) -> None:
    repo = scratch / "evidence-repo"
    (repo / ".logs/old").mkdir(parents=True)
    (repo / ".logs/ad-feedback-current").mkdir()
    (repo / ".logs/giant-bombcast-reference").mkdir()
    (repo / ".logs/retention-old").mkdir()
    (repo / ".logs/pinned-dir/nested").mkdir(parents=True)
    (repo / "outside").mkdir()
    (repo / "README.md").write_text(
        "See `.logs/pinned-dir/` for evidence. See:.logs/punctuation-colon/receipt.json, "
        "[.logs/punctuation-bracket/receipt.json].")
    (repo / "INVARIANTS.md").write_text("See `.logs/pinned-dir/nested/receipt.json`.")
    (repo / "TASKS.md").write_text("No other references.")
    paths = [
        repo / ".logs/old/build.log",
        repo / ".logs/ad-feedback-current/receipt.json",
        repo / ".logs/giant-bombcast-reference/status.json",
        repo / ".logs/retention-old/result.json",
        repo / ".logs/pinned-dir/nested/receipt.json",
        repo / ".logs/pinned-dir-unrelated/receipt.json",
        repo / "outside/receipt.json",
    ]
    paths.extend((repo / ".logs/punctuation-colon/receipt.json",
                  repo / ".logs/punctuation-bracket/receipt.json"))
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(path.name)
        old(path)
    assert evidence.protected(repo / ".logs/ad-feedback-current/receipt.json")
    assert evidence.protected(repo / ".logs/giant-bombcast-reference/status.json")
    assert evidence.protected(repo / ".logs/retention-old/result.json")
    selected = set(evidence.candidates(repo))
    assert paths[0] in selected
    assert paths[5] in selected
    assert paths[1] not in selected and paths[2] not in selected
    assert paths[3] not in selected and paths[4] not in selected and paths[6] not in selected
    assert paths[7] not in selected and paths[8] not in selected
    paths[5].unlink()

    # Failed archive creation and a source changed during packing both keep the source.
    source = paths[0]
    with mock.patch("retention.evidence._open_reference", return_value=(False, "")), \
            mock.patch("retention.evidence.archive_paths", side_effect=ArchiveError("injected pack error")):
        report = evidence.compact(repo, repo / ".logs/retained-evidence/failed", apply=True)
    assert report["status"] == "kept" and source.exists()

    real_archive = archive_paths

    def mutate_before_pack(selected_paths, root, destination, **kwargs):
        source.write_text("new generation")
        return real_archive(selected_paths, root, destination, **kwargs)

    with mock.patch("retention.evidence._open_reference", return_value=(False, "")), \
            mock.patch("retention.evidence.archive_paths", side_effect=mutate_before_pack):
        report = evidence.compact(repo, repo / ".logs/retained-evidence/changed", apply=True)
    assert report["status"] == "kept" and source.read_text() == "new generation"

    # Default is dry-run and never traverses the repository outside .logs.
    source.write_text("old again")
    old(source)
    dry = evidence.compact(repo, repo / ".logs/retained-evidence/dry")
    assert dry["status"] == "dry-run" and source.exists()


def test_source_export_integration(scratch: Path) -> None:
    repo = scratch / "source-repo"
    logs = repo / ".logs"
    logs.mkdir(parents=True)
    source = logs / "old-source.zip"
    source.write_bytes(b"container")
    old(source)
    (repo / "README.md").write_text("No pins.")
    (repo / "INVARIANTS.md").write_text("No pins.")
    (repo / "TASKS.md").write_text("No pins.")
    export_root = logs / "retained-evidence/.fake-export"
    payload = b'{"members":[]}'
    sha = hashlib.sha256(payload).hexdigest()
    expected = snapshot_tree(source, root=source.parent)
    fake = {"status": "compacted", "source_fingerprint": expected.digest,
            "output_directory": str(export_root),
            "outputs": [{"path": "source-snapshot.json", "bytes": len(payload), "sha256": sha}],
            "result": None}

    def export(_path: Path, destination: Path, *, deadline=None):
        destination.mkdir()
        (destination / "source-snapshot.json").write_bytes(payload)
        fake["output_directory"] = str(destination)
        return fake

    with mock.patch("retention.evidence.export_bundle", side_effect=export), \
            mock.patch("retention.evidence._open_reference", return_value=(False, "")):
        result = evidence.compact(repo, logs / "retained-evidence/weekly", apply=True)
    assert result["status"] == "removed" and not source.exists()
    pack = Path(result["archives"][0])
    recovered = verify_archive(pack)
    assert any(row["path"].endswith("source-snapshot.json") for row in recovered["files"])


def test_lsof_external_smbfs_warning(scratch: Path) -> None:
    target = scratch / "lsof-target"
    target.mkdir()
    target_device = target.lstat().st_dev
    mount = "/Volumes/.timemachine/truenas._smb._tcp.local./backup/timemachine"

    def warning(path: str, device: str) -> bytes:
        return ("lsof: WARNING: can't stat() smbfs file system {}\n"
                "      Output information may be incomplete.\n"
                "      assuming \"dev={}\" from mount table\n".format(path, device)).encode()

    distinct = warning(mount, str(target_device + 1000))
    assert core.lsof_only_external_smbfs_warning(distinct, target)
    assert not core.lsof_only_external_smbfs_warning(warning(mount, str(target_device)), target)
    assert not core.lsof_only_external_smbfs_warning(
        warning(mount, format(target_device, "x")), target)
    assert not core.lsof_only_external_smbfs_warning(
        warning(str(target / "nested-mount"), str(target_device + 1000)), target)
    assert not core.lsof_only_external_smbfs_warning(
        warning(str(target.parent), str(target_device + 1000)), target)
    assert not core.lsof_only_external_smbfs_warning(
        distinct + b"additional warning\n", target)
    assert not core.lsof_only_external_smbfs_warning(
        distinct + distinct, target)
    assert not core.lsof_only_external_smbfs_warning(
        distinct.replace(b"smbfs", b"nfs"), target)

    accepted = subprocess.CompletedProcess((), 1, b"", distinct)
    same_device = subprocess.CompletedProcess(
        (), 1, b"", warning(mount, str(target_device)))
    unknown = subprocess.CompletedProcess((), 1, b"", distinct + b"other\n")
    with mock.patch("retention.evidence.shutil.which", return_value="/usr/sbin/lsof"), \
            mock.patch("retention.evidence.subprocess.run", return_value=accepted):
        assert evidence._open_reference(target) == (False, "")
    with mock.patch("retention.evidence.shutil.which", return_value="/usr/sbin/lsof"), \
            mock.patch("retention.evidence.subprocess.run", return_value=same_device):
        assert evidence._open_reference(target)[0]
    with mock.patch("retention.evidence.shutil.which", return_value="/usr/sbin/lsof"), \
            mock.patch("retention.evidence.subprocess.run", return_value=unknown):
        assert evidence._open_reference(target)[0]

    with mock.patch("retention.backups.subprocess.run", return_value=accepted):
        assert not backups._in_use(target)
    with mock.patch("retention.backups.subprocess.run", return_value=same_device):
        assert backups._in_use(target)
    with mock.patch("retention.backups.subprocess.run", return_value=unknown):
        assert backups._in_use(target)

    with mock.patch("retention.caches.shutil.which", return_value="/usr/sbin/lsof"), \
            mock.patch("retention.caches.subprocess.run", return_value=accepted):
        assert caches._cache_idle(target, None) == (True, "")
    with mock.patch("retention.caches.shutil.which", return_value="/usr/sbin/lsof"), \
            mock.patch("retention.caches.subprocess.run", return_value=same_device):
        assert caches._cache_idle(target, None)[0] is False
    with mock.patch("retention.caches.shutil.which", return_value="/usr/sbin/lsof"), \
            mock.patch("retention.caches.subprocess.run", return_value=unknown):
        assert caches._cache_idle(target, None)[0] is False


def _make_backup(root: Path, version: int, days_old: float, suffix: str) -> Path:
    path = root / f"library.sqlite.v{version}-backup-{suffix}"
    path.mkdir()
    connection = sqlite3.connect(path / "library.sqlite")
    connection.execute("CREATE TABLE sample (value TEXT)")
    connection.execute("INSERT INTO sample VALUES ('ok')")
    connection.commit()
    connection.close()
    for child in path.iterdir():
        old(child, days_old)
    old(path, days_old)
    return path


def test_backups(scratch: Path) -> None:
    root = scratch / "backup-root"
    root.mkdir()
    names = ["11111111-1111-4111-8111-111111111111",
             "22222222-2222-4222-8222-222222222222",
             "33333333-3333-4333-8333-333333333333",
             "44444444-4444-4444-8444-444444444444"]
    backups_by_age = [_make_backup(root, version, 60 - version, names[version - 1])
                      for version in range(1, 5)]
    # A read-only check must ignore SQLite's transient SHM/directory touches
    # when ranking age; the audited database timestamp remains authoritative.
    oldest = backups_by_age[0]
    database = oldest / "library.sqlite"
    wal = oldest / "library.sqlite-wal"
    shm = oldest / "library.sqlite-shm"
    wal.write_bytes(b"")
    shm.write_bytes(b"s" * 32768)
    touched = time.time()
    os.utime(wal, (touched, touched))
    os.utime(shm, (touched, touched))
    os.utime(oldest, (touched, touched))
    database_mtime = database.stat().st_mtime
    assert backups._timestamp(oldest) == database_mtime

    def metadata(path: Path) -> tuple[int, int, int, int]:
        info = path.lstat()
        return info.st_size, info.st_mtime_ns, info.st_ctime_ns, info.st_ino

    untouched = {path: metadata(path) for path in (oldest, database, wal, shm)}
    manual = root / "library.sqlite.manual-before-import"
    manual.mkdir()
    (manual / "library.sqlite").write_text("keep")
    unknown = root / "library.sqlite.v5-backup-not-a-uuid"
    unknown.mkdir()
    (unknown / "library.sqlite").write_text("keep")
    report = backups.plan(root)
    assert report["status"] == "complete"
    assert {path: metadata(path) for path in untouched} == untouched
    rows = {Path(row["path"]): row for row in report["backups"]}
    assert rows[backups_by_age[0]]["status"] == "eligible"
    assert all(rows[path]["status"] == "retained" for path in backups_by_age[1:])
    with mock.patch("retention.backups._in_use", return_value=False):
        applied = backups.plan(root, apply=True)
    assert applied["status"] == "complete"
    assert not backups_by_age[0].exists()
    assert all(path.exists() for path in backups_by_age[1:])
    assert manual.exists() and unknown.exists()

    # A nonempty WAL is checked only through a verified scratch copy.
    wal_repo = scratch / "wal-check"
    wal_repo.mkdir()
    wal_database = wal_repo / "library.sqlite"
    connection = sqlite3.connect(wal_database)
    assert connection.execute("PRAGMA journal_mode=WAL").fetchone() == ("wal",)
    connection.execute("CREATE TABLE sample (value TEXT)")
    connection.execute("INSERT INTO sample VALUES ('uncheckpointed')")
    connection.commit()
    wal_file = Path(str(wal_database) + "-wal")
    shm_file = Path(str(wal_database) + "-shm")
    assert wal_file.stat().st_size > 0
    wal_sources = (wal_database, wal_file, shm_file, wal_repo)
    before_check = {path: metadata(path) for path in wal_sources}
    assert backups.quick_check(wal_database)
    assert {path: metadata(path) for path in wal_sources} == before_check
    connection.close()


def test_cache_safety_and_locks(scratch: Path) -> None:
    timeout_repo = scratch / "timeout-cache-repo"
    timeout_build = timeout_repo / ".build"
    timeout_build.mkdir(parents=True)
    timeout_lock = timeout_build / "full-run.lock"
    real_read_text = Path.read_text

    def alarm_during_lock_record_read(path, *args, **kwargs):
        if path == timeout_lock / "pid":
            signal.setitimer(signal.ITIMER_REAL, 0.01)
            time.sleep(0.05)
        return real_read_text(path, *args, **kwargs)

    def raise_timeout(_signum, _frame):
        raise TimeoutError("injected run deadline")

    previous_handler = signal.signal(signal.SIGALRM, raise_timeout)
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    try:
        with mock.patch("retention.caches._live_build_process", return_value=(False, "")), \
                mock.patch("retention.caches._owner_started", return_value="Wed Nov  4 12:00:00 2026"), \
                mock.patch("pathlib.Path.read_text", autospec=True,
                           side_effect=alarm_during_lock_record_read):
            try:
                timeout_result = caches.evict(timeout_repo, budget=1, apply=False)
            except TimeoutError:
                pass
            else:
                raise AssertionError(
                    "SIGALRM did not interrupt full-run lock cleanup; "
                    f"result={timeout_result}")
    finally:
        signal.setitimer(signal.ITIMER_REAL, *previous_timer)
        signal.signal(signal.SIGALRM, previous_handler)
    assert not timeout_lock.exists(), "deadline left this run's lock behind"
    with mock.patch("retention.caches._live_build_process", return_value=(False, "")), \
            mock.patch("retention.caches._owner_started", return_value="Wed Nov  4 12:00:00 2026"):
        retry = caches.evict(timeout_repo, budget=1, apply=False)
    assert retry["status"] == "within-budget", retry

    empty_repo = scratch / "empty-cache-repo"
    empty_swiftpm = empty_repo / ".build/swiftpm"
    empty_swiftpm.mkdir(parents=True)
    empty_units = []
    for index in range(32):
        unit = empty_swiftpm / f"empty-{index:02d}"
        unit.mkdir()
        old(unit, 3)
        empty_units.append(unit)
    nonempty = empty_swiftpm / "large-unit"
    nonempty.mkdir()
    (nonempty / "payload.bin").write_bytes(b"cache-data" * 4096)
    old(nonempty / "payload.bin", 3)
    old(nonempty, 3)
    probed_units: list[Path] = []

    def idle_unit(path: Path, deadline: float | None) -> tuple[bool, str]:
        probed_units.append(path)
        return True, ""

    real_cache_snapshot = caches._cache_snapshot
    with mock.patch("retention.caches._live_build_process", return_value=(False, "")), \
            mock.patch("retention.caches._owner_started", return_value="Wed Nov  4 12:00:00 2026"), \
            mock.patch("retention.caches._cache_idle", side_effect=idle_unit), \
            mock.patch("retention.caches._cache_snapshot", wraps=real_cache_snapshot) as snapshotter:
        empty_report = caches.evict(empty_repo, budget=0, min_age=0, preserve=(), apply=False)
    snapshot_units = [call.args[1][0] for call in snapshotter.call_args_list]
    empty_rows = {Path(row["path"]): row for row in empty_report["units"]}
    assert empty_report["status"] == "complete", empty_report
    assert all(empty_rows[unit]["status"] == "empty" for unit in empty_units)
    assert empty_rows[nonempty]["status"] == "evictable"
    assert probed_units == [nonempty, nonempty], probed_units
    assert all(snapshot_units.count(unit) == 1 for unit in empty_units)
    assert nonempty in snapshot_units

    small_repo = scratch / "small-cache-repo"
    small_cache = small_repo / ".build/swiftpm/small-key"
    small_cache.mkdir(parents=True)
    (small_cache / "payload.bin").write_bytes(b"small cache payload")
    expected_bytes = caches._size(small_cache)
    with mock.patch("retention.caches._live_build_process", return_value=(False, "")), \
            mock.patch("retention.caches._owner_started", return_value="Wed Nov  4 12:00:00 2026"), \
            mock.patch("retention.caches._cache_snapshot", side_effect=AssertionError(
                "under-budget cache performed a content snapshot")):
        within_budget = caches.evict(small_repo, budget=expected_bytes + 1, apply=False)
    assert within_budget["status"] == "within-budget", within_budget
    assert within_budget["remaining_bytes"] == expected_bytes
    assert within_budget["units"][0]["bytes"] == expected_bytes

    repo = scratch / "cache-repo"
    build = repo / ".build"
    cache = build / "swiftpm/cache-key"
    (cache / "payload").mkdir(parents=True)
    (cache / "payload/data").write_text("payload")
    (cache / "relative-link").symlink_to("payload/data")
    (cache / "absolute-link").symlink_to(str((cache / "payload/data").resolve()))
    snap = caches._cache_snapshot(build, (cache,), unit_root=cache)
    assert snap.bytes > 0

    external = scratch / "external-sentinel"
    external.write_text("untouched")
    outside_cache = build / "swiftpm/external-link-cache"
    outside_cache.mkdir(parents=True)
    (outside_cache / "escape").symlink_to(external)
    try:
        caches._cache_snapshot(build, (outside_cache,), unit_root=outside_cache)
    except ArchiveError:
        pass
    else:
        raise AssertionError("cache symlink escaping its unit was accepted")
    assert external.read_text() == "untouched"
    shutil.rmtree(outside_cache)

    # `comm` supplies only executable identity, so arguments mentioning
    # Swift or SwiftShader and Chrome's GPU helper do not create false hits.
    def ps_result(*commands: str) -> subprocess.CompletedProcess:
        output = "".join("{} {}\n".format(index + 100, command)
                         for index, command in enumerate(commands)).encode()
        return subprocess.CompletedProcess(("/bin/ps",), 0, output, b"")

    unrelated = (
        "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
        "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)",
        "/Users/example/.agent/bin/agy",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
    )
    with mock.patch("retention.caches.subprocess.run", return_value=ps_result(*unrelated)) as probe:
        assert caches._live_build_process() == (False, "")
    probe.assert_called_once_with(('/bin/ps', '-axo', 'pid=,comm='),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  timeout=3, check=False)

    for active in sorted(caches.BUILD_PROCESS_BASENAMES):
        command = "/Applications/Xcode.app/Contents/Developer/usr/bin/" + active
        with mock.patch("retention.caches.subprocess.run", return_value=ps_result(command)):
            assert caches._live_build_process() == (True, "build-or-test-process-active")

    malformed = subprocess.CompletedProcess(("/bin/ps",), 0, b"not-a-process-record\n", b"")
    with mock.patch("retention.caches.subprocess.run", return_value=malformed):
        assert caches._live_build_process() == (True, "process-probe-unknown")
    empty = subprocess.CompletedProcess(("/bin/ps",), 0, b"", b"")
    with mock.patch("retention.caches.subprocess.run", return_value=empty):
        assert caches._live_build_process() == (True, "process-probe-unknown")
    failed = subprocess.CompletedProcess(("/bin/ps",), 1, b"", b"ps unavailable")
    with mock.patch("retention.caches.subprocess.run", return_value=failed):
        assert caches._live_build_process() == (True, "process-probe-unknown")

    with mock.patch("retention.caches._owner_started", return_value="Wed Nov  4 12:00:00 2026"):
        lock, lock_identity, started = caches._acquire_full_run(build)
    owner = (lock / "pid").read_text().splitlines()
    assert owner == [f"pid={os.getpid()}", f"started={started}"]
    caches._release_full_run(lock, lock_identity, started)
    assert not lock.exists()

    def recovery_during_acquire(pid: int) -> str:
        (build / "full-run.lock.recovery").mkdir()
        return "Wed Nov  4 12:00:00 2026"

    with mock.patch("retention.caches._owner_started", side_effect=recovery_during_acquire):
        try:
            caches._acquire_full_run(build)
        except ArchiveError:
            pass
        else:
            raise AssertionError("full-run lock ignored an appearing recovery guard")
    assert not (build / "full-run.lock").exists()
    (build / "full-run.lock.recovery").rmdir()

    # A lock contention blocks eviction; a successful dry run never deletes.
    old(cache / "payload/data", 3)
    old(cache / "payload", 3)
    old(cache / "relative-link", 3)
    old(cache / "absolute-link", 3)
    old(cache, 3)
    with mock.patch("retention.caches._live_build_process", return_value=(False, "")), \
            mock.patch("retention.caches._cache_idle", return_value=(True, "")), \
            mock.patch("retention.caches._owner_started", return_value="Wed Nov  4 12:00:00 2026"):
        lock_path = build / "swiftpm/.locks/cache-key.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
        import fcntl
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        report = caches.evict(repo, budget=0, min_age=0, preserve=(), apply=False)
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)
    assert report["status"] == "over-budget-protected", report
    assert report["units"][0]["status"] == "protected-lock-busy"
    assert cache.exists()
    with mock.patch("retention.caches._live_build_process", return_value=(False, "")), \
            mock.patch("retention.caches._cache_idle", return_value=(True, "")), \
            mock.patch("retention.caches._owner_started", return_value="Wed Nov  4 12:00:00 2026"):
        report = caches.evict(repo, budget=0, min_age=0, preserve=(), apply=True)
    assert report["status"] == "complete"
    assert not cache.exists()
    assert external.read_text() == "untouched"


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="retention-policy-") as raw:
        scratch = Path(raw).resolve()
        test_core(scratch)
        test_evidence_policy(scratch)
        test_source_export_integration(scratch)
        test_backups(scratch)
        test_lsof_external_smbfs_warning(scratch)
        test_cache_safety_and_locks(scratch)
        cli = ROOT / "scripts/storage-retention.py"
        backup_fixture = scratch / "empty-backup-root"
        backup_fixture.mkdir()
        result = subprocess.run([sys.executable, str(cli), "--repo", str(scratch),
                                 "--backup-root", str(backup_fixture), "--budget-seconds", "10"],
                                capture_output=True, text=True, check=True)
        cli_report = json.loads(result.stdout)
        assert cli_report["status"] == "complete" and cli_report["mode"] == "dry-run"
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
