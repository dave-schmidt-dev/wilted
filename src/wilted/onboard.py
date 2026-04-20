"""Interactive onboarding and pipeline orchestration for wilted.

wilted setup  — walk a new user through feed + keyword configuration
wilted ingest — run the full nightly pipeline: discover → classify → report
"""

from __future__ import annotations

import logging
import sys
import time

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Starter feed suggestions
# ---------------------------------------------------------------------------

STARTER_FEEDS: list[dict[str, str]] = [
    # --- Tech / Engineering ---
    {
        "url": "https://feeds.arstechnica.com/arstechnica/index",
        "title": "Ars Technica",
        "type": "article",
        "playlist": "Work",
    },
    {
        "url": "https://www.theverge.com/rss/index.xml",
        "title": "The Verge",
        "type": "article",
        "playlist": "Work",
    },
    {
        "url": "https://simonwillison.net/atom/everything/",
        "title": "Simon Willison",
        "type": "article",
        "playlist": "Work",
    },
    {
        "url": "https://blog.pragmaticengineer.com/rss/",
        "title": "Pragmatic Engineer",
        "type": "article",
        "playlist": "Work",
    },
    # --- Security ---
    {
        "url": "https://krebsonsecurity.com/feed/",
        "title": "Krebs on Security",
        "type": "article",
        "playlist": "Work",
    },
    {
        "url": "https://www.schneier.com/feed/atom/",
        "title": "Schneier on Security",
        "type": "article",
        "playlist": "Work",
    },
    # --- Science / Education ---
    {
        "url": "https://www.quantamagazine.org/feed",
        "title": "Quanta Magazine",
        "type": "article",
        "playlist": "Education",
    },
    # --- Podcasts ---
    {
        "url": "https://feeds.megaphone.fm/darknetdiaries",
        "title": "Darknet Diaries",
        "type": "podcast",
        "playlist": "Education",
    },
    {
        "url": "https://lexfridman.com/feed/podcast/",
        "title": "Lex Fridman Podcast",
        "type": "podcast",
        "playlist": "Education",
    },
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _prompt(message: str, default: str = "") -> str:
    """Read a line from stdin with an optional default shown."""
    if default:
        raw = input(f"{message} [{default}]: ").strip()
        return raw or default
    return input(f"{message}: ").strip()


def _confirm(message: str, default: bool = True) -> bool:
    """Yes/no prompt."""
    suffix = " [Y/n]" if default else " [y/N]"
    raw = input(f"{message}{suffix}: ").strip().lower()
    if not raw:
        return default
    return raw in ("y", "yes")


def _print_stage(label: str) -> None:
    """Print a stage header."""
    print(f"\n{'─' * 50}")
    print(f"  {label}")
    print(f"{'─' * 50}\n")


# ---------------------------------------------------------------------------
# wilted setup
# ---------------------------------------------------------------------------


def run_setup() -> None:
    """Interactive first-run setup: feeds, keywords, optional first ingestion."""
    from wilted.feeds import add_feed, list_feeds

    print()
    print("  Welcome to Wilted")
    print("  Local-first personal audio for news, podcasts, and learning")
    print()

    existing = list_feeds()
    if existing:
        print(f"You already have {len(existing)} feed(s) configured.")
        if not _confirm("Start setup anyway?", default=False):
            return

    # --- Step 1: Starter feeds ---
    _print_stage("Step 1: Add feeds")
    print("Wilted discovers content from RSS feeds. You can add article")
    print("feeds (news, blogs) and podcast feeds.\n")

    if _confirm("Browse starter feed suggestions?"):
        print()
        for i, feed in enumerate(STARTER_FEEDS, 1):
            tag = "podcast" if feed["type"] == "podcast" else "article"
            print(f"  {i:2d}. [{tag:7s}] {feed['title']}")
            print(f"      {feed['url']}")

        print()
        print("Enter numbers to add (e.g. '1 3 5 8'), 'all', or 'none':")
        choice = input("> ").strip().lower()

        if choice == "all":
            indices = list(range(len(STARTER_FEEDS)))
        elif choice in ("none", ""):
            indices = []
        else:
            indices = []
            for tok in choice.split():
                try:
                    idx = int(tok) - 1
                    if 0 <= idx < len(STARTER_FEEDS):
                        indices.append(idx)
                except ValueError:
                    pass

        added_count = 0
        for idx in indices:
            feed = STARTER_FEEDS[idx]
            try:
                result = add_feed(
                    feed["url"],
                    feed_type=feed["type"],
                    title=feed["title"],
                    default_playlist=feed.get("playlist"),
                )
                print(f"  + {result.title}")
                added_count += 1
            except ValueError as e:
                print(f"  (skip) {feed['title']}: {e}")

        if added_count:
            print(f"\nAdded {added_count} feed(s).")

    # Custom feed
    print()
    while _confirm("Add a custom feed URL?", default=False):
        url = _prompt("Feed URL")
        if not url:
            continue
        feed_type = _prompt("Type (article/podcast)", default="article")
        if feed_type not in ("article", "podcast"):
            print("  Must be 'article' or 'podcast'.")
            continue
        title = _prompt("Title (optional, auto-detected from feed)", default="")
        playlist = _prompt("Default playlist (Work/Fun/Education)", default="")
        try:
            result = add_feed(
                url,
                feed_type=feed_type,
                title=title or None,
                default_playlist=playlist or None,
            )
            print(f"  + {result.title}")
        except ValueError as e:
            print(f"  Error: {e}")

    # --- Step 2: Keywords ---
    _print_stage("Step 2: Relevance keywords (optional)")
    print("Keywords influence how Wilted scores content relevance.")
    print("Higher-weight keywords push matching content up in your report.\n")

    if _confirm("Add relevance keywords?", default=False):
        from wilted.preferences import add_keyword

        while True:
            kw = _prompt("Keyword (or blank to finish)")
            if not kw:
                break
            weight = _prompt("Weight", default="1.0")
            try:
                result = add_keyword(kw, weight=float(weight))
                print(f"  + '{result.keyword}' (weight: {result.weight:.1f})")
            except (ValueError, TypeError) as e:
                print(f"  Error: {e}")

    # --- Step 3: First ingestion ---
    feeds = list_feeds()
    if feeds:
        _print_stage("Step 3: First ingestion")
        print(f"You have {len(feeds)} feed(s). Run the discovery pipeline now?")
        print("This will: poll feeds → fetch articles → classify → build report.\n")

        if _confirm("Run first ingestion?"):
            run_ingest()
        else:
            print("\nYou can run it later with: wilted ingest")
    else:
        print("\nNo feeds added. Add feeds later with: wilted feed add <url>")

    # --- Done ---
    print()
    print("Setup complete. Next steps:")
    print("  wilted           Launch the TUI (shows morning report if available)")
    print("  wilted ingest    Run the discovery pipeline")
    print("  wilted feed add  Add more feeds")
    print("  wilted doctor    Check system health")
    print()


# ---------------------------------------------------------------------------
# wilted ingest
# ---------------------------------------------------------------------------


def run_ingest(
    *,
    skip_discover: bool = False,
    skip_classify: bool = False,
    skip_report: bool = False,
) -> dict:
    """Run the full nightly pipeline: discover → classify → report.

    Each stage prints progress and continues even if a prior stage had
    partial failures. Returns aggregate stats.

    Args:
        skip_discover: Skip the discovery stage.
        skip_classify: Skip the classification stage.
        skip_report: Skip the report generation stage.

    Returns:
        Dict with per-stage stats.
    """
    results: dict[str, dict | str] = {}
    start = time.monotonic()

    # --- Stage 1: Discover ---
    if not skip_discover:
        _print_stage("Stage 1/3: Discovery")
        print("Polling feeds for new content...")
        try:
            from wilted.discover import run_discover

            stats = run_discover()
            results["discover"] = stats
            print(f"  Found {stats['discovered']} new items from {stats['feeds_polled']} feeds")
            if stats["errors"]:
                print(f"  {stats['errors']} feed(s) had errors (see /tmp/wilted.log)")
        except Exception as e:
            results["discover"] = {"error": str(e)}
            print(f"  Discovery failed: {e}", file=sys.stderr)
    else:
        print("\n  (skipping discovery)")

    # --- Stage 2: Classify ---
    if not skip_classify:
        _print_stage("Stage 2/3: Classification")
        print("Loading LLM and classifying new items...")
        try:
            from wilted.classify import run_classify

            stats = run_classify()
            results["classify"] = stats
            print(f"  Classified {stats['classified']} items")
            if stats["errors"]:
                print(f"  {stats['errors']} item(s) had errors")
        except Exception as e:
            results["classify"] = {"error": str(e)}
            print(f"  Classification failed: {e}", file=sys.stderr)
    else:
        print("\n  (skipping classification)")

    # --- Stage 3: Report ---
    if not skip_report:
        _print_stage("Stage 3/3: Morning Report")
        print("Assembling today's report...")
        try:
            from wilted.report import get_report, run_report

            run_report()
            report_data = get_report()
            if report_data:
                items_dict = report_data["items"]
                total = sum(len(v) for v in items_dict.values())
                playlists = ", ".join(f"{k}: {len(v)}" for k, v in sorted(items_dict.items()))
                results["report"] = {
                    "total_items": total,
                    "playlists": playlists,
                }
                print(f"  Report ready: {total} items ({playlists})")
                print("\n  Launch the TUI to review and select items: wilted")
                print("  Or prepare selected items for playback:    wilted prepare")
            else:
                results["report"] = {"total_items": 0}
                print("  No items to report.")
        except Exception as e:
            results["report"] = {"error": str(e)}
            print(f"  Report generation failed: {e}", file=sys.stderr)
    else:
        print("\n  (skipping report)")

    elapsed = time.monotonic() - start
    print(f"\n{'─' * 50}")
    print(f"  Ingestion complete in {elapsed:.1f}s")
    print(f"{'─' * 50}")

    return results
