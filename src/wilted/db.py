"""Peewee ORM models and database management for wilted.

All timestamps are stored as UTC ISO 8601 strings ('2026-04-18T06:00:00Z').
The database uses WAL mode so the TUI can read while nightly batches write.

Thread-local connections: each thread (including Textual @work threads) must
call connect_db() or use the worker_db() context manager before touching models.

Usage:
    from wilted.db import connect_db, worker_db, Item, Feed
    connect_db(DATA_DIR / "wilted.db")
    items = list(Item.select().where(Item.status == "ready"))
"""

import logging
import threading
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from peewee import (
    SQL,
    BooleanField,
    CharField,
    FloatField,
    ForeignKeyField,
    IntegerField,
    Model,
    SqliteDatabase,
    TextField,
)

logger = logging.getLogger(__name__)


def now_utc() -> str:
    """Return current UTC time as ISO 8601 string (e.g. '2026-04-20T12:00:00Z')."""
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_db() -> None:
    """Connect to the database if not already connected. Safe to call multiple times."""
    import wilted

    connect_db(wilted.DATA_DIR / "wilted.db")


# ---------------------------------------------------------------------------
# Database instance — initialized by connect_db(); thread-local connections
# ---------------------------------------------------------------------------

# Peewee's SqliteDatabase uses thread-local connections automatically.
_db = SqliteDatabase(
    None,  # path set by connect_db()
    pragmas={
        "journal_mode": "wal",
        "synchronous": "NORMAL",
        "busy_timeout": 5000,
        "cache_size": -65536,
        "foreign_keys": 1,
    },
)

_connect_lock = threading.Lock()


def connect_db(path: Path | str) -> SqliteDatabase:
    """Open the database at *path*, applying WAL pragmas.

    Safe to call multiple times — subsequent calls on the same thread reuse
    the existing connection. Creates the file if it does not exist.

    Args:
        path: Filesystem path to wilted.db.

    Returns:
        The initialized SqliteDatabase instance.
    """
    with _connect_lock:
        if _db.database is None:
            _db.init(str(path))
    if not _db.is_connection_usable():
        _db.connect(reuse_if_open=True)
    return _db


@contextmanager
def worker_db(path: Path | str | None = None):
    """Context manager for Textual @work thread connections.

    Opens a per-thread connection on entry and closes it on exit.
    Pass *path* only when the database has not yet been initialized.

    Usage inside a Textual worker::

        async def on_mount(self) -> None:
            self.run_worker(self._load_items)

        def _load_items(self) -> None:
            with worker_db():
                items = list(Item.select().where(Item.status == "ready"))
    """
    if path is not None and _db.database is None:
        _db.init(str(path))
    _db.connect(reuse_if_open=True)
    try:
        yield _db
    finally:
        if not _db.is_closed():
            _db.close()


# ---------------------------------------------------------------------------
# Base model
# ---------------------------------------------------------------------------


class BaseModel(Model):
    class Meta:
        database = _db


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


class Feed(BaseModel):
    """An RSS/Atom feed subscription."""

    title = CharField()
    feed_url = CharField(unique=True)
    site_url = CharField(null=True)
    feed_type = CharField(constraints=[SQL("CHECK(feed_type IN ('article', 'podcast'))")])
    default_playlist = CharField(null=True)
    enabled = BooleanField(default=True)
    last_checked_at = CharField(null=True)
    etag = CharField(null=True)
    last_modified = CharField(null=True)
    created_at = CharField()
    updated_at = CharField()

    class Meta:
        table_name = "feeds"


class Report(BaseModel):
    """A morning report record (one per day)."""

    report_date = CharField(unique=True)
    generated_at = CharField()
    item_count = IntegerField()
    metadata = TextField(
        null=True,
        constraints=[SQL("CHECK(metadata IS NULL OR json_valid(metadata))")],
    )

    class Meta:
        table_name = "reports"


class Item(BaseModel):
    """A content item — either an article or a podcast episode."""

    feed = ForeignKeyField(Feed, backref="items", null=True, on_delete="SET NULL")
    guid = CharField(null=True)
    title = CharField()
    author = CharField(null=True)
    source_name = CharField(null=True)
    source_url = CharField(null=True)
    canonical_url = CharField(null=True)
    published_at = CharField(null=True)
    discovered_at = CharField()
    item_type = CharField(constraints=[SQL("CHECK(item_type IN ('article', 'podcast_episode'))")])
    status = CharField(
        constraints=[
            SQL(
                "CHECK(status IN ("
                "'discovered', 'fetched', 'classified', "
                "'selected', 'processing', 'ready', "
                "'completed', 'expired', 'skipped', 'error'"
                "))"
            )
        ]
    )
    status_changed_at = CharField()
    error_message = TextField(null=True)
    word_count = IntegerField(null=True)
    duration_seconds = FloatField(null=True)
    transcript_file = CharField(null=True)
    audio_file = CharField(null=True)
    enclosure_url = CharField(null=True)
    enclosure_type = CharField(null=True)
    playlist_assigned = CharField(null=True)
    playlist_override = CharField(null=True)
    relevance_score = FloatField(null=True)
    summary = TextField(null=True)
    tags = TextField(null=True)
    keep = BooleanField(default=False)
    metadata = TextField(
        null=True,
        constraints=[SQL("CHECK(metadata IS NULL OR json_valid(metadata))")],
    )

    class Meta:
        table_name = "items"
        constraints = [SQL("UNIQUE(feed_id, guid)")]
        indexes = (
            (("status", "discovered_at"), False),
            (("feed_id",), False),
        )


class Playlist(BaseModel):
    """A named playlist — dynamic (expiry) or static (manual ordering)."""

    name = CharField(unique=True)
    playlist_type = CharField(constraints=[SQL("CHECK(playlist_type IN ('dynamic', 'static'))")])
    expiry_days = IntegerField(null=True, default=7)
    created_at = CharField()

    class Meta:
        table_name = "playlists"


class PlaylistItem(BaseModel):
    """Association between a playlist and an item."""

    playlist = ForeignKeyField(Playlist, backref="playlist_items", on_delete="CASCADE")
    item = ForeignKeyField(Item, backref="playlist_memberships", on_delete="CASCADE")
    added_at = CharField()
    position = IntegerField(null=True)

    class Meta:
        table_name = "playlist_items"
        constraints = [SQL("UNIQUE(playlist_id, item_id)")]


class SelectionHistory(BaseModel):
    """Record of user selection or skip for a report item."""

    item = ForeignKeyField(Item, backref="selection_history", on_delete="CASCADE")
    report = ForeignKeyField(Report, backref="selections", null=True, on_delete="SET NULL")
    selected = BooleanField()
    selected_at = CharField(null=True)

    class Meta:
        table_name = "selection_history"


class Keyword(BaseModel):
    """A user-defined relevance keyword with optional weight."""

    keyword = CharField(unique=True)
    weight = FloatField(default=1.0)
    created_at = CharField()

    class Meta:
        table_name = "keywords"


class SourceStat(BaseModel):
    """Weekly per-feed selection statistics."""

    feed = ForeignKeyField(Feed, backref="stats", on_delete="CASCADE")
    period_start = CharField()
    period_end = CharField()
    items_discovered = IntegerField(default=0)
    items_selected = IntegerField(default=0)
    selection_rate = FloatField(null=True)

    class Meta:
        table_name = "source_stats"
        constraints = [SQL("UNIQUE(feed_id, period_start)")]


# ---------------------------------------------------------------------------
# All models — used by migration runner and tests
# ---------------------------------------------------------------------------

ALL_MODELS = [
    Feed,
    Report,
    Item,
    Playlist,
    PlaylistItem,
    SelectionHistory,
    Keyword,
    SourceStat,
]


# ---------------------------------------------------------------------------
# Migration tracking — _meta table, not in ALL_MODELS
# ---------------------------------------------------------------------------


class _Meta(BaseModel):
    """Internal key/value metadata table used by the migration runner."""

    key = CharField(primary_key=True)
    value = CharField()

    class Meta:
        table_name = "_meta"


# ---------------------------------------------------------------------------
# User settings — stored in _meta with "setting:" prefix
# ---------------------------------------------------------------------------


def get_setting(key: str, default: str | None = None) -> str | None:
    """Read a user setting from the _meta table."""
    ensure_db()
    try:
        row = _Meta.get_by_id(f"setting:{key}")
        return row.value
    except _Meta.DoesNotExist:
        return default


def set_setting(key: str, value: str) -> None:
    """Write a user setting to the _meta table."""
    ensure_db()
    _Meta.replace(key=f"setting:{key}", value=str(value)).execute()


# ---------------------------------------------------------------------------
# Migration runner
# ---------------------------------------------------------------------------


def run_migrations(db_path: Path | str, migrations_dir: Path | None = None) -> None:
    """Run pending schema migrations against the database at *db_path*.

    Migrations are Python files in *migrations_dir* named ``NNN_*.py``
    (e.g. ``001_initial.py``).  Each must expose an ``up(db)`` function.
    Already-applied migrations are skipped; the runner is safe to call on
    every startup.

    Startup order guaranteed by cli.py: logging → run_migrations → tqdm lock → TUI.

    Args:
        db_path:        Path to wilted.db (created if absent).
        migrations_dir: Directory containing migration scripts.  Defaults to
                        ``migrations/`` adjacent to the project root.
    """
    connect_db(db_path)

    if migrations_dir is None:
        # Resolve relative to this file: src/wilted/db.py → project_root/migrations/
        migrations_dir = Path(__file__).resolve().parent.parent.parent / "migrations"

    _db.create_tables([_Meta], safe=True)

    try:
        row = _Meta.get_by_id("schema_version")
        current_version = int(row.value)
    except _Meta.DoesNotExist:
        _Meta.create(key="schema_version", value="0")
        current_version = 0

    logger.debug("Current schema version: %d", current_version)

    migration_files = sorted(migrations_dir.glob("[0-9]*.py"))
    for mig_file in migration_files:
        try:
            version = int(mig_file.stem.split("_")[0])
        except ValueError:
            logger.warning("Skipping non-numeric migration file: %s", mig_file.name)
            continue

        if version <= current_version:
            continue

        logger.info("Applying migration %03d: %s", version, mig_file.name)

        import importlib.util as _ilu

        spec = _ilu.spec_from_file_location(f"migration_{version:03d}", mig_file)
        module = _ilu.module_from_spec(spec)
        spec.loader.exec_module(module)

        with _db.atomic():
            module.up(_db)
            _Meta.update(value=str(version)).where(_Meta.key == "schema_version").execute()

        current_version = version
        logger.info("Migration %03d applied successfully", version)


# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------


def reset_db() -> None:
    """Close and de-initialize the database singleton.

    For use in tests only.  After calling this, the next :func:`connect_db`
    call will initialize ``_db`` with a new path, giving each test an isolated
    SQLite database.
    """
    if not _db.is_closed():
        _db.close()
    _db.init(None)  # Reset to uninitialized; triggers re-init on next connect_db()
