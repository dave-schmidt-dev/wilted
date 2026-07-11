"""Content-addressed immutable media store + owners index.

The durable, dedup'd home for finalized playable audio (podcasts, assembled
articles, and — later — ephemeral weather bulletins). Every published
artifact is named by the SHA-256 of its bytes, so identical content is
stored exactly once regardless of how many entries reference it.

Layout
------
Blobs live under ``wilted.DATA_DIR / "media"``, sharded two hex characters
deep to avoid a single directory ever holding an unbounded number of
entries::

    media/<sha256[:2]>/<sha256>

e.g. a SHA-256 of ``abcdef01...`` is stored at ``media/ab/abcdef01...``. The
full 64-character hex digest is always the filename; the two-character
shard prefix is purely a directory-fanout optimization and carries no
independent meaning (it is always the first two characters of the same
digest, so it is never out of sync with the filename).

Immutability
------------
:func:`publish` never rewrites or truncates an existing blob. If
``media/<ab>/<sha256>`` already exists, publishing identical bytes is a
no-op — the existing file is left completely untouched and the same hash is
returned. This is safe because the filename *is* the content hash: two
different byte sequences cannot collide onto the same path (short of a
SHA-256 collision, which is out of scope). New content is written to a
tempfile in the same shard directory and atomically moved into place with
``os.replace`` (mirrors ``wilted.cache.save_manifest`` and
``wilted.station_runtime.store.JsonStationStore._write_doc``), so a reader
never observes a partially written blob.

INV-4 (no empty/zero-byte publish): :func:`publish` refuses empty input —
zero-byte bytes/files raise :class:`EmptyMediaError` rather than being
silently stored under the (well-known) SHA-256 of the empty string. A
consequence of INV-4 is that a zero-byte file found sitting at a
content-addressed path can never be a legitimate prior publish — only
external corruption (e.g. a crash or an out-of-band write) — so
:func:`publish` treats it as absent and repairs it rather than trusting the
filename.

Owners index
------------
Persisted as a single JSON document at ``wilted.DATA_DIR /
"media_owners.json"``, atomically written (tempfile + ``os.replace``, same
pattern as the blob store). Maps each hash to the set of things that
currently own/reference it::

    {
      "<sha256>": [
        {"kind": "item", "entry_id": "item-42", "expiry": null},
        {"kind": "bulletin", "entry_id": "wx-2026-07-10T12:00Z", "expiry": "2026-07-10T13:00:00Z"}
      ]
    }

``kind`` mirrors ``wilted.station.models.EntryKind`` (``"item"`` for durable
saved content, ``"bulletin"`` for ephemeral session-scoped audio). This is
exactly the distinction a later GC pass (Task 4.4) needs: durable Item
media must never be collected, regardless of expiry, while bulletin media
may be collected once its owning entries have all expired.

Multi-owner policy: a single hash can legitimately be referenced by more
than one entry (e.g. two station entries that happen to publish identical
bytes, or a re-publish with a new ``entry_id``/``expiry``). Owners
therefore form a *set*, keyed by ``(kind, entry_id)`` — recording an owner
for a ``(kind, entry_id)`` pair that is already present updates that
owner's ``expiry`` in place (last-writer-wins for that pair's metadata)
rather than appending a duplicate row. Distinct ``(kind, entry_id)`` pairs
coexist independently. This means GC can safely delete a hash's blob only
once every owner row for that hash has been removed/expired — never based
on a single "last owner wins the whole hash" rule.

INV-5: ``wilted.DATA_DIR`` is resolved by attribute access on the ``wilted``
module at *call time* in every function below, never imported as a bare
name at module scope — see ``wilted.cache`` for the full rationale. This
lets tests redirect all I/O by monkeypatching the live ``wilted.DATA_DIR``
attribute.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import tempfile
from typing import TYPE_CHECKING, Literal

import wilted

if TYPE_CHECKING:
    from pathlib import Path

MediaKind = Literal["item", "bulletin"]

_OWNERS_FILENAME = "media_owners.json"
_OWNERS_LOCK_FILENAME = "media_owners.json.lock"
_SHARD_PREFIX_LEN = 2


class EmptyMediaError(ValueError):
    """Raised when :func:`publish` is asked to store empty/zero-byte content.

    INV-4: no pipeline stage may publish empty/unfinalized content.
    """


class MediaOwnersCorruptError(Exception):
    """Raised when ``media_owners.json`` exists but cannot be safely read.

    The owners index is authoritative, not a cache: a later GC pass (Task
    4.4) consults it to decide what audio it may delete. Silently treating
    an unreadable file as empty would drop durable-media owner rows and let
    GC delete durable audio it must never touch. So an existing-but-corrupt
    file is always a hard refusal — never a silent ``{}``. An *absent* file
    is unaffected by this and still means "no owners recorded yet".
    """


def _media_root() -> Path:
    """Return ``wilted.DATA_DIR / "media"`` resolved at call time (INV-5)."""
    return wilted.DATA_DIR / "media"


def _owners_path() -> Path:
    """Return ``wilted.DATA_DIR / "media_owners.json"`` resolved at call time (INV-5)."""
    return wilted.DATA_DIR / _OWNERS_FILENAME


def _owners_lock_path() -> Path:
    """Return the sidecar lock file path for the owners index (INV-5)."""
    return wilted.DATA_DIR / _OWNERS_LOCK_FILENAME


@contextlib.contextmanager
def _owners_write_lock():
    """Hold an exclusive OS file lock across the owners doc's read-modify-write.

    The owners index is intended to be written by the single controller
    writer (SR-1); this flock is defense-in-depth on top of that, closing
    the lost-update window where two concurrent :func:`record_owner` calls
    could each load the same document, add their own row, and have the
    second ``os.replace`` silently drop the first row's write.
    """
    lock_path = _owners_lock_path()
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("w") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_file, fcntl.LOCK_UN)


def _shard_dir(sha256: str) -> Path:
    """Return the shard directory for a given hex digest (``media/<ab>``)."""
    return _media_root() / sha256[:_SHARD_PREFIX_LEN]


def path_for(sha256: str) -> Path | None:
    """Resolve a SHA-256 hex digest to its immutable on-disk path.

    Returns ``None`` if no blob for ``sha256`` exists. Never raises for a
    merely-absent hash.
    """
    candidate = _shard_dir(sha256) / sha256
    if candidate.exists():
        return candidate
    return None


def exists(sha256: str) -> bool:
    """Return True if ``sha256`` already has a published blob."""
    return path_for(sha256) is not None


def _read_all_bytes(src: str | bytes | Path) -> bytes:
    """Normalize ``src`` (bytes, or a path to a file) into its raw bytes."""
    if isinstance(src, bytes):
        return src
    from pathlib import Path as _Path

    return _Path(src).read_bytes()


def publish(src: str | bytes) -> str:
    """Publish content into the immutable store, returning its SHA-256 hex digest.

    Args:
        src: Either the raw bytes to publish, or a path (``str``/``Path``)
            to a file whose bytes should be published.

    Returns:
        The SHA-256 hex digest of the published bytes. If a non-empty blob
        with that hash already exists, this is a no-op (the existing blob
        is never rewritten) and the same hash is returned. If the file at
        that content-addressed path exists but is zero bytes — which INV-4
        guarantees can never be a legitimate prior publish, only on-disk
        corruption — it is repaired in place with the correct bytes.

    Raises:
        EmptyMediaError: If ``src`` resolves to zero bytes (INV-4).
    """
    data = _read_all_bytes(src)
    if len(data) == 0:
        raise EmptyMediaError(
            "refusing to publish empty/zero-byte media (INV-4: no pipeline stage may publish empty/unfinalized content)"
        )

    sha256 = hashlib.sha256(data).hexdigest()
    shard_dir = _shard_dir(sha256)
    dest = shard_dir / sha256

    # A legitimately-published blob is never empty (INV-4 forbids publishing
    # zero-byte content), so a zero-byte file at this content-addressed path
    # cannot be a real prior publish — it can only be external/on-disk
    # corruption (e.g. a crash mid-write, or something outside this module
    # truncating it). Fall through and repair it rather than trusting the
    # filename. A *non-empty* existing blob is still trusted as-is and never
    # re-hashed/rewritten: the filename is the content hash, so re-verifying
    # every publish would mean re-reading every blob on every call, which is
    # too expensive for the (assumed-durable) common case.
    if dest.exists() and dest.stat().st_size > 0:
        # Immutable store: identical content already published. No-op.
        return sha256

    shard_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=shard_dir, suffix=".tmp", delete=False) as f:
        f.write(data)
        tmp_path = f.name
    os.replace(tmp_path, dest)
    return sha256


def publish_file(src_path: str | Path) -> str:
    """Publish an existing file's bytes into the store.

    Convenience wrapper around :func:`publish` for callers that have a
    filesystem path rather than in-memory bytes. Delegates straight to
    :func:`publish` (single hashing code path); the whole file is read into
    memory, which is fine for the media sizes this store handles
    (podcast/article audio) — revisit if truly large files show up.
    """
    return publish(str(src_path))


# ---------------------------------------------------------------------------
# Owners index
# ---------------------------------------------------------------------------


def _load_owners_doc() -> dict[str, list[dict]]:
    """Load the owners index document, or an empty dict if it has never been written.

    The absent-vs-unreadable distinction is based solely on ``path.exists()``.
    An absent file is the normal empty-start case and returns ``{}``. A file
    that exists but is not valid JSON, or whose top-level parsed value is not
    a dict, is unreadable, not empty — it must never be treated as "no
    owners recorded" and silently returned as ``{}``, since that would drop
    durable-media owner rows out from under GC (Task 4.4).

    Raises:
        MediaOwnersCorruptError: If the file exists but is not valid JSON,
            is not decodable as UTF-8 text, or its top-level parsed value is
            not a JSON object (dict).
    """
    path = _owners_path()
    if not path.exists():
        return {}
    try:
        with path.open() as f:
            doc = json.load(f)
    except json.JSONDecodeError as exc:
        raise MediaOwnersCorruptError(f"media owners index at {path} is corrupt (invalid JSON): {exc!r}") from exc
    except UnicodeDecodeError as exc:
        raise MediaOwnersCorruptError(f"media owners index at {path} is not valid UTF-8 text: {exc!r}") from exc
    if not isinstance(doc, dict):
        raise MediaOwnersCorruptError(
            f"media owners index at {path} does not contain a JSON object at its "
            f"top level (got {type(doc).__name__}); refusing to read (and will not "
            "overwrite it)"
        )
    return doc


def _write_owners_doc(doc: dict[str, list[dict]]) -> None:
    """Atomically write the owners index document (tempfile + os.replace)."""
    path = _owners_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, suffix=".tmp", delete=False) as f:
        json.dump(doc, f, indent=2)
        tmp_path = f.name
    os.replace(tmp_path, path)


def record_owner(sha256: str, kind: MediaKind, entry_id: str, expiry: str | None = None) -> None:
    """Record (or update) an owner of ``sha256`` in the owners index.

    Args:
        sha256: The content hash being owned (need not already exist in the
            blob store, though callers normally call this immediately after
            :func:`publish`).
        kind: ``"item"`` for durable saved content, ``"bulletin"`` for
            ephemeral session-scoped audio. Distinguishes what a later GC
            pass (Task 4.4) may ever delete — durable Item media must
            never be collected.
        entry_id: Identifier of the owning entry (e.g. a ``StationEntry.entry_id``).
        expiry: UTC ISO-8601 'Z' string after which this *owner* no longer
            needs the media, or ``None`` if it never expires.

    Policy: owners are a set keyed by ``(kind, entry_id)``. Calling this
    again for the same ``(kind, entry_id)`` pair updates that owner's
    ``expiry`` in place rather than appending a duplicate row. Distinct
    ``(kind, entry_id)`` pairs for the same hash coexist independently, so
    a hash referenced by multiple entries keeps all of their owner records.

    Concurrency: the owners index is intended to be written by the single
    controller writer (SR-1). As defense-in-depth, the load-mutate-write
    below is serialized with an OS file lock (see ``_owners_write_lock``)
    so that concurrent ``record_owner`` calls cannot race a read-modify-
    write and silently drop each other's rows.
    """
    if kind not in ("item", "bulletin"):
        raise ValueError(f"record_owner: kind must be 'item' or 'bulletin', got {kind!r}")
    if not entry_id:
        raise ValueError("record_owner: entry_id must be non-empty")

    with _owners_write_lock():
        doc = _load_owners_doc()
        owners = doc.setdefault(sha256, [])

        for owner in owners:
            if owner["kind"] == kind and owner["entry_id"] == entry_id:
                owner["expiry"] = expiry
                break
        else:
            owners.append({"kind": kind, "entry_id": entry_id, "expiry": expiry})

        _write_owners_doc(doc)


def get_owners(sha256: str) -> list[dict]:
    """Return the list of owner records for ``sha256``.

    Each record is a dict with ``kind``, ``entry_id``, and ``expiry`` keys.
    Returns an empty list if ``sha256`` has no recorded owners (this is not
    an error — a hash may exist in the blob store without an owners entry,
    or vice versa, since the two are updated independently).
    """
    doc = _load_owners_doc()
    return list(doc.get(sha256, []))


def publish_with_owner(
    src: str | bytes,
    kind: MediaKind,
    entry_id: str,
    expiry: str | None = None,
) -> str:
    """Publish content and record its owner in a single call.

    Convenience wrapper combining :func:`publish` and :func:`record_owner` —
    the common case for callers finalizing a new playable artifact.

    Returns:
        The SHA-256 hex digest of the published bytes (see :func:`publish`).
    """
    sha256 = publish(src)
    record_owner(sha256, kind=kind, entry_id=entry_id, expiry=expiry)
    return sha256
