#!/usr/bin/env python3
"""Import reviewed feed placement hints into Wilted's private profile sidecar."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import errno
import fcntl
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
import tempfile
import time
from typing import Any
from urllib.parse import quote

from wilted_worker.feed_profiles import validate_observation, validate_profile

CORE_DATA_EPOCH = 978307200.0
MAX_FILE_BYTES = 1_048_576
MAX_FEEDS = 256
MAX_OBSERVATIONS = 20
STORE_KEYS = {"schemaVersion", "feeds"}
RECORD_KEYS = {"feedID", "subscriptionEpoch", "profile", "importedProfile", "observations"}
IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Build JSON objects while rejecting ambiguous duplicate keys."""
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def _identifier(value: Any) -> bool:
    return isinstance(value, str) and IDENTIFIER_RE.fullmatch(value) is not None


def _safe_path(path: str | Path, label: str) -> Path:
    """Reject a symlink target before resolving its parent."""
    candidate = Path(path).expanduser()
    try:
        if stat.S_ISLNK(os.lstat(candidate).st_mode):
            raise ValueError(f"{label} cannot be a symlink")
    except FileNotFoundError:
        pass
    return candidate.absolute()


def _read_limited(path: Path, label: str, limit: int = MAX_FILE_BYTES) -> bytes:
    """Read a bounded regular file without following a final-component symlink."""
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError(f"{label} is not a bounded regular file")
        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(descriptor, min(65_536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > limit:
            raise ValueError(f"{label} exceeds the {limit}-byte limit")
        return data
    finally:
        os.close(descriptor)


def read_subscriptions(library: str | Path) -> dict[str, float]:
    """Read exact persisted subscription IDs and epochs through a read-only SQLite URI."""
    path = _safe_path(library, "Library database")
    # Verify the database inode without following a final-component symlink.
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("Library database is not a regular file")
    finally:
        os.close(descriptor)
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro"
    try:
        with sqlite3.connect(uri, uri=True, timeout=1) as connection:
            rows = connection.execute(
                "SELECT ZFEEDID, ZSUBSCRIBEDAT, ZENABLED "
                "FROM ZPODCASTSUBSCRIPTIONRECORD"
            ).fetchall()
    except sqlite3.Error as error:
        raise ValueError("Could not read the subscription table") from error

    result: dict[str, float] = {}
    for feed_id, raw_epoch, enabled in rows:
        if not _identifier(feed_id) or type(enabled) not in (int, bool) or raw_epoch is None:
            raise ValueError("Subscription table contains an invalid record")
        if feed_id in result:
            raise ValueError("Subscription table contains duplicate feed IDs")
        if type(raw_epoch) not in (float, int) or type(raw_epoch) is bool:
            raise ValueError("Subscription table contains an invalid timestamp")
        try:
            epoch = float(raw_epoch) + CORE_DATA_EPOCH
        except OverflowError as error:
            raise ValueError("Subscription table contains a non-finite timestamp") from error
        if not math.isfinite(epoch):
            raise ValueError("Subscription table contains a non-finite timestamp")
        # Swift treats every persisted subscription as active profile identity,
        # including a temporarily disabled feed. Do not use ZENABLED to drop it.
        result[feed_id] = epoch
    if len(result) > MAX_FEEDS:
        raise ValueError("Subscription count exceeds the profile feed limit")
    return result


def _decode(data: bytes, label: str) -> Any:
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=_pairs,
                          parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("non-finite JSON number")))
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError(f"{label} contains invalid JSON") from error


def load_profiles(path: str | Path, subscriptions: dict[str, float]) -> dict[str, dict[str, str]]:
    """Load the complete import list and validate every envelope before a write."""
    source = _safe_path(path, "Profiles input")
    document = _decode(_read_limited(source, "Profiles input"), "Profiles input")
    if not isinstance(document, dict) or set(document) != {"profiles"} or not isinstance(document["profiles"], list):
        raise ValueError("Profiles input must contain only a profiles array")
    if len(document["profiles"]) > MAX_FEEDS:
        raise ValueError("Profiles input exceeds the feed limit")
    result: dict[str, dict[str, str]] = {}
    for envelope in document["profiles"]:
        if not isinstance(envelope, dict) or set(envelope) != {"payload", "digest"}:
            raise ValueError("Profile entry has an invalid envelope")
        payload = envelope["payload"]
        if not isinstance(payload, str):
            raise ValueError("Profile payload must be a JSON string")
        try:
            payload_data = payload.encode("utf-8")
        except UnicodeError as error:
            raise ValueError("Profile payload is not valid UTF-8") from error
        decoded = _decode(payload_data, "Profile payload")
        if (not isinstance(decoded, dict) or not _identifier(decoded.get("feedID"))
                or type(decoded.get("revision")) is not int or decoded["revision"] > 9_223_372_036_854_775_807):
            raise ValueError("Profile payload has an invalid feed identity or revision")
        feed_id = decoded["feedID"]
        if feed_id not in subscriptions:
            raise ValueError("Profile feed is not present in the subscription table")
        if feed_id in result or validate_profile(envelope, feed_id) is None:
            raise ValueError("Profile envelope is duplicate or invalid")
        # Preserve the original payload bytes exactly for Swift validation.
        result[feed_id] = {"payload": payload, "digest": envelope["digest"]}
    return result


def load_store(path: Path) -> dict[str, Any] | None:
    """Read and fully validate an existing sidecar; refuse to overwrite corruption."""
    try:
        data = _decode(_read_limited(path, "Profile store"), "Profile store")
    except FileNotFoundError:
        return None
    if not isinstance(data, dict) or set(data) != STORE_KEYS or type(data["schemaVersion"]) is not int or data["schemaVersion"] != 1:
        raise ValueError("Profile store has an unsupported structure")
    records = data["feeds"]
    if not isinstance(records, list) or len(records) > MAX_FEEDS:
        raise ValueError("Profile store exceeds its feed limit")
    seen: set[str] = set()
    for record in records:
        if not isinstance(record, dict) or set(record) != RECORD_KEYS:
            raise ValueError("Profile store has an invalid feed record")
        feed_id = record["feedID"]
        if not _identifier(feed_id) or feed_id in seen:
            raise ValueError("Profile store has a duplicate or invalid feed ID")
        seen.add(feed_id)
        epoch = record["subscriptionEpoch"]
        if type(epoch) not in (int, float):
            raise ValueError("Profile store has an invalid subscription epoch")
        try:
            finite_epoch = math.isfinite(epoch)
        except OverflowError:
            finite_epoch = False
        if not finite_epoch:
            raise ValueError("Profile store has an invalid subscription epoch")
        for key in ("profile", "importedProfile"):
            envelope = record[key]
            if envelope is not None and (not isinstance(envelope, dict)
                    or validate_profile(envelope, feed_id) is None):
                raise ValueError("Profile store contains an invalid envelope")
        observations = record["observations"]
        if not isinstance(observations, list) or len(observations) > MAX_OBSERVATIONS:
            raise ValueError("Profile store exceeds its observation limit")
        seen_episode_ids: set[str] = set()
        seen_source_hashes: set[str] = set()
        for observation in observations:
            if not isinstance(observation, dict):
                raise ValueError("Profile store contains an invalid observation")
            episode_id = observation.get("episodeID")
            source_hash = observation.get("sourceHash")
            if (not _identifier(episode_id) or episode_id in seen_episode_ids
                    or source_hash in seen_source_hashes
                    or validate_observation(observation, feed_id, episode_id, source_hash) is None):
                raise ValueError("Profile store contains an invalid or duplicate observation")
            seen_episode_ids.add(episode_id)
            seen_source_hashes.add(source_hash)
    return data


def reconcile(subscriptions: dict[str, float], existing: dict[str, Any] | None,
              imported: dict[str, dict[str, str]]) -> tuple[dict[str, Any], dict[str, int]]:
    """Merge current membership, retaining unchanged feed evidence and imports."""
    old = {row["feedID"]: row for row in (existing or {}).get("feeds", [])}
    feeds = []
    preserved = reset = 0
    for feed_id, epoch in sorted(subscriptions.items()):
        prior = old.get(feed_id)
        same = prior is not None and prior["subscriptionEpoch"] == epoch
        if same:
            preserved += 1
        elif prior is not None:
            reset += 1
        feeds.append({
            "feedID": feed_id,
            "subscriptionEpoch": epoch,
            "profile": prior["profile"] if same else None,
            "importedProfile": imported.get(feed_id, prior["importedProfile"] if same else None),
            "observations": prior["observations"] if same else [],
        })
    document = {"schemaVersion": 1, "feeds": feeds}
    if len(feeds) > MAX_FEEDS:
        raise ValueError("Reconciled store exceeds its feed limit")
    return document, {"imported": len(imported), "feeds": len(feeds), "active": len(subscriptions),
                      "preserved": preserved, "reset": reset,
                      "removed": len(set(old).difference(subscriptions))}


def _write_atomic(path: Path, document: dict[str, Any]) -> None:
    """Publish a private sidecar with fsync and same-directory atomic replace."""
    encoded = json.dumps(document, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(encoded) > MAX_FILE_BYTES:
        raise ValueError("Reconciled store exceeds the 1 MiB limit")
    temporary: str | None = None
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
        with os.fdopen(descriptor, "wb") as output:
            if not stat.S_ISREG(os.fstat(output.fileno()).st_mode):
                raise ValueError("Temporary profile file is not regular")
            os.fchmod(output.fileno(), 0o600)
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        # Atomic rename never follows a final symlink; refuse one observed before replacement.
        try:
            if stat.S_ISLNK(os.lstat(path).st_mode):
                raise ValueError("Profile store cannot be a symlink")
        except FileNotFoundError:
            pass
        os.replace(temporary, path)
        temporary = None
        parent = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass


@contextmanager
def _store_lock(path: Path, timeout: float):
    """Acquire the permanent sibling lock using bounded nonblocking flock."""
    if not math.isfinite(timeout) or not 0 <= timeout <= 60:
        raise ValueError("Lock timeout must be between 0 and 60 seconds")
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Profile lock is not a regular file")
        os.fchmod(descriptor, 0o600)
        deadline = time.monotonic() + timeout
        reported = False
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as error:
                if error.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES, errno.EINTR):
                    raise ValueError("Could not acquire profile store lock") from error
                if time.monotonic() >= deadline:
                    raise TimeoutError("Timed out acquiring profile store lock") from error
                if not reported:
                    print("Waiting for profile store lock", file=sys.stderr, flush=True)
                    reported = True
                time.sleep(min(0.05, max(0.001, deadline - time.monotonic())))
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def import_profiles(library: str | Path, profiles: str | Path,
                    store: str | Path | None = None, *, dry_run: bool = False,
                    lock_timeout: float = 10.0) -> dict[str, int]:
    """Import validated exact-feed profiles and reconcile the private store."""
    library_path = _safe_path(library, "Library database")
    profiles_path = _safe_path(profiles, "Profiles input")
    store_path = _safe_path(store, "Profile store") if store is not None else library_path.parent / "ad-placement-profiles.json"
    parent = store_path.parent
    if parent.is_symlink() or not parent.is_dir():
        raise ValueError("Profile store parent must be an existing directory")
    lock_path = parent / (store_path.name + ".lock")
    if dry_run:
        subscriptions = read_subscriptions(library_path)
        imported = load_profiles(profiles_path, subscriptions)
        document, stats = reconcile(subscriptions, load_store(store_path), imported)
        if len(json.dumps(document, ensure_ascii=False).encode("utf-8")) > MAX_FILE_BYTES:
            raise ValueError("Reconciled store exceeds the 1 MiB limit")
        print(f"dry-run imported={stats['imported']} feeds={stats['feeds']} active={stats['active']} "
              f"preserved={stats['preserved']} reset={stats['reset']} removed={stats['removed']}")
        return stats
    with _store_lock(lock_path, lock_timeout):
        # Membership is read under the same lock as store read/merge/write.
        subscriptions = read_subscriptions(library_path)
        imported = load_profiles(profiles_path, subscriptions)
        document, stats = reconcile(subscriptions, load_store(store_path), imported)
        _write_atomic(store_path, document)
    print(f"imported={stats['imported']} feeds={stats['feeds']} active={stats['active']} "
          f"preserved={stats['preserved']} reset={stats['reset']} removed={stats['removed']}")
    return stats


def main(argv: list[str] | None = None) -> int:
    """Run the bounded local import command."""
    parser = argparse.ArgumentParser(description="Import feed ad-placement profiles.")
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--profiles", required=True, type=Path)
    parser.add_argument("--store", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--lock-timeout", type=float, default=10.0)
    args = parser.parse_args(argv)
    try:
        import_profiles(args.library, args.profiles, args.store, dry_run=args.dry_run, lock_timeout=args.lock_timeout)
        return 0
    except (OSError, ValueError, TimeoutError, sqlite3.Error):
        print("Profile import failed; input and local state were not accepted.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
