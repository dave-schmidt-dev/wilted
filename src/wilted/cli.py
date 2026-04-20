"""CLI commands for wilted — extracted from the root wilted script for testability."""

import argparse
import os
import subprocess
import sys

from wilted import VOICES, WPM_ESTIMATE
from wilted.fetch import get_text_from_clipboard, get_text_from_url
from wilted.ingest import resolve_article
from wilted.log import setup_logging
from wilted.queue import (
    add_article,
    clear_queue,
    get_article_text,
    load_queue,
    mark_completed,
    remove_article,
    utc_to_local_date,
)
from wilted.text import clean_text


class CLIError(Exception):
    """Raised by CLI commands to signal a user-facing error."""


# ---------------------------------------------------------------------------
# Subcommand dispatch helpers
# ---------------------------------------------------------------------------

# Old --flag → new subcommand name (for translation in both directions)
_SUBCMD_TO_FLAG = {
    "add": "--add",
    "list": "--list",
    "play": "--play",
    "next": "--next",
    "clear": "--clear",
}

# Phase 2+ pipeline and management subcommands — stubbed until implemented.
_STUB_SUBCMDS = frozenset()


def _normalize_argv(argv: list[str]) -> list[str]:
    """Translate new subcommand argv to legacy flag argv.

    Allows ``wilted list`` and ``wilted --list`` to both work.

    Examples::

        ['add', 'URL']   → ['--add', 'URL']
        ['remove', '3']  → ['--remove', '3']
        ['list']         → ['--list']
    """
    if not argv:
        return argv
    first = argv[0]
    if first in _SUBCMD_TO_FLAG:
        return [_SUBCMD_TO_FLAG[first]] + argv[1:]
    if first == "remove":
        return ["--remove"] + argv[1:]
    return argv


def _run_stub(argv: list[str]) -> None:
    """Print a 'not yet implemented' message for Phase 2+ subcommands."""
    cmd = argv[0]
    print(f"'{cmd}' is not yet implemented (coming in Phase 2+).", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# PROJECT_ROOT validation (Task 1.4)
# ---------------------------------------------------------------------------


def validate_project_root() -> None:
    """Verify PROJECT_ROOT is sane and data/ is writable.

    Raises:
        RuntimeError: If PROJECT_ROOT does not contain pyproject.toml or
            data/ cannot be created/written to.  The message includes
            instructions for setting WILTED_PROJECT_ROOT.
    """
    from wilted import DATA_DIR, PROJECT_ROOT

    if not (PROJECT_ROOT / "pyproject.toml").exists():
        raise RuntimeError(
            f"PROJECT_ROOT '{PROJECT_ROOT}' does not contain pyproject.toml.\n"
            "Set the WILTED_PROJECT_ROOT environment variable to the correct path, e.g.:\n"
            "  export WILTED_PROJECT_ROOT=/path/to/wilted"
        )

    try:
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        probe = DATA_DIR / ".write_probe"
        probe.touch()
        probe.unlink()
    except OSError as e:
        raise RuntimeError(
            f"data/ directory '{DATA_DIR}' is not writable: {e}\n"
            "Check directory permissions or set WILTED_PROJECT_ROOT."
        ) from e


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_add(args):
    """Add an article to the reading list from URL or clipboard."""
    try:
        result = resolve_article(
            url=args.input if args.input and args.input.startswith(("http://", "https://")) else None,
            on_status=lambda msg: print(msg),
        )
    except ValueError as e:
        raise CLIError(str(e)) from e

    entry = add_article(
        result.text,
        title=result.title,
        source_url=result.source_url,
        canonical_url=result.canonical_url,
    )

    est_min = entry["words"] / WPM_ESTIMATE
    print(f"Added #{entry['id']}: {entry['title']}")
    print(f"  {entry['words']} words, ~{est_min:.0f} min listen time")
    queue = load_queue()
    print(f"  Queue now has {len(queue)} article(s).")


def cmd_list(args):
    """Show the reading list."""
    queue = load_queue()
    if not queue:
        print("Reading list is empty.")
        return

    total_words = 0
    print(f"Reading list ({len(queue)} articles):\n")
    for i, entry in enumerate(queue, 1):
        words = entry.get("words", 0)
        total_words += words
        est = words / WPM_ESTIMATE
        added = utc_to_local_date(entry.get("added", ""))
        print(f"  {i}. {entry['title']}")
        print(f"     {words} words, ~{est:.0f} min | added {added}")

    total_min = total_words / WPM_ESTIMATE
    print(f"\nTotal: ~{total_words} words, ~{total_min:.0f} min listen time")


def cmd_remove(args):
    """Remove an article from the reading list by number."""
    try:
        entry = remove_article(args.remove - 1)
    except IndexError as e:
        raise CLIError(str(e)) from e

    print(f"Removed: {entry['title']}")
    queue = load_queue()
    print(f"Queue now has {len(queue)} article(s).")


def cmd_clear(args):
    """Clear the entire reading list."""
    count = clear_queue()
    if count == 0:
        print("Reading list is already empty.")
    else:
        print(f"Cleared {count} article(s) from reading list.")


def _play_text(text, args):
    """Generate and play TTS audio for text using AudioEngine.

    Returns True if playback completed, False if interrupted.
    """
    from wilted.engine import AudioEngine

    word_count = len(text.split())
    est_minutes = word_count / WPM_ESTIMATE
    print(f"  {word_count} words, ~{est_minutes:.0f} min listen time")

    engine = AudioEngine(model_name=args.model, voice=args.voice, speed=args.speed, lang=args.lang)

    if args.save:
        from wilted.engine import export_to_wav
        from wilted.text import split_into_chunks

        chunks = split_into_chunks(text)
        print(f"  {len(chunks)} chunks. Generating...")

        def on_progress(current, total):
            sys.stdout.write(f"\r  Generating {current}/{total}...")
            sys.stdout.flush()

        try:
            export_to_wav(engine, chunks, args.save, on_progress=on_progress)
            print(f"\n  Saved to {args.save}")
        except ValueError as e:
            print(f"\n  {e}", file=sys.stderr)
    else:
        # Stream playback via AudioEngine.play_article
        from wilted.text import split_paragraphs

        paragraphs = split_paragraphs(text)
        print(f"  {len(paragraphs)} paragraphs. Playing... (Ctrl+C to stop)\n")

        def on_progress(para_idx, seg_idx, total_paras, current_text):
            sys.stdout.write(f"\r  Paragraph {para_idx + 1}/{total_paras}")
            sys.stdout.flush()

        try:
            engine.play_article(text, on_progress=on_progress)
            print("\n  Done.")
        except KeyboardInterrupt:
            engine.stop()
            print("\n  Stopped.")
            return False

    return True


def cmd_play(args):
    """Play all articles in the reading list sequentially."""
    queue = load_queue()
    if not queue:
        print("Reading list is empty. Add articles with: wilted --add URL")
        return

    print(f"Playing {len(queue)} article(s)...\n")
    completed = []
    for i, entry in enumerate(queue):
        text = get_article_text(entry)
        if text is None:
            print(f"Skipping #{entry['id']}: cached file missing")
            continue

        print(f"[{i + 1}/{len(queue)}] {entry['title']}")
        finished = _play_text(text, args)
        if finished:
            completed.append(entry)
        else:
            break

    if completed:
        for entry in completed:
            mark_completed(entry)
        remaining = load_queue()
        print(f"\nFinished {len(completed)} article(s). {len(remaining)} remaining.")


def cmd_next(args):
    """Play the next article in the reading list."""
    queue = load_queue()
    if not queue:
        print("Reading list is empty. Add articles with: wilted --add URL")
        return

    entry = queue[0]
    text = get_article_text(entry)
    if text is None:
        remove_article(0)
        raise CLIError(f"Cached file missing for: {entry['title']}")

    print(f"Now playing: {entry['title']}")
    finished = _play_text(text, args)

    if finished:
        mark_completed(entry)
        remaining = load_queue()
        if remaining:
            print(f"{len(remaining)} article(s) remaining.")
        else:
            print("Reading list is now empty.")


def cmd_direct(args):
    """Play text directly from URL, file, stdin, or clipboard."""
    text = None

    if args.input == "-":
        text = sys.stdin.read()
    elif args.input:
        if args.input.startswith(("http://", "https://")):
            print("Fetching article...")
            text, _ = get_text_from_url(args.input)
            if not text:
                raise CLIError("Could not extract article text (paywall?). Try: wilted --add")
        elif os.path.isfile(args.input):
            with open(args.input) as f:
                text = f.read()
        else:
            raise CLIError(f"File not found: {args.input}")
    elif not sys.stdin.isatty():
        text = sys.stdin.read()
    else:
        print("Reading from clipboard...")
        text = get_text_from_clipboard()

    if not text or not text.strip():
        raise CLIError("No text found.")

    text = clean_text(text)

    if args.clean:
        print(text)
        return

    _play_text(text, args)


def cmd_list_voices():
    """Print available Kokoro voices grouped by accent."""
    print("Kokoro voices:\n")
    for accent in ["American", "British", "Japanese", "Chinese"]:
        voices = [f"{code} ({v['name']}, {v['gender']})" for code, v in VOICES.items() if v["accent"] == accent]
        if voices:
            print(f"  {accent}: {', '.join(voices)}")


def cmd_doctor(_argv: list[str] | None = None) -> None:
    """Print diagnostic path and configuration info."""
    import shutil

    from wilted import DATA_DIR, PROJECT_ROOT

    db_path = DATA_DIR / "wilted.db"
    config_path = PROJECT_ROOT / "wilted.toml"

    print("wilted doctor\n")
    print(f"  PROJECT_ROOT : {PROJECT_ROOT}")
    print(f"  DATA_DIR     : {DATA_DIR}")
    print(f"  DB path      : {db_path}  ({'exists' if db_path.exists() else 'missing'})")
    print(f"  Config path  : {config_path}  ({'exists' if config_path.exists() else 'using defaults'})")
    print(f"  pyproject    : {(PROJECT_ROOT / 'pyproject.toml').exists()}")

    data_writable = os.access(DATA_DIR, os.W_OK) if DATA_DIR.exists() else False
    print(f"  data/ writable: {data_writable}")

    ffmpeg = shutil.which("ffmpeg")
    print(f"  ffmpeg       : {ffmpeg or 'NOT FOUND'}")

    # Email-alert check
    email_alert = os.path.expanduser("~/.agent/bin/email-alert")
    print(f"  email-alert  : {email_alert}  ({'exists' if os.path.exists(email_alert) else 'NOT FOUND'})")

    email_config = _load_email_config()
    email_status = "enabled" if email_config["enabled"] else "disabled"
    email_to = email_config["to"] or "(not set)"
    print(f"  Email        : {email_status}, to={email_to}")

    # Playlist health
    try:
        from wilted.playlists import ensure_default_playlists, list_playlists

        ensure_default_playlists()
        playlists = list_playlists()
        print(f"  Playlists    : {len(playlists)} ({', '.join(p.name for p in playlists)})")
    except Exception as e:
        print(f"  Playlists    : error — {e}")


# ---------------------------------------------------------------------------
# Phase 2 — Feed management subcommands
# ---------------------------------------------------------------------------


def cmd_feed(argv: list[str]) -> None:
    """Dispatch feed subcommands: add, list, remove."""
    if not argv:
        print("Usage: wilted feed <add|list|remove> [args]", file=sys.stderr)
        sys.exit(1)

    action = argv[0]

    if action == "add":
        parser = argparse.ArgumentParser(prog="wilted feed add")
        parser.add_argument("url", help="Feed URL")
        parser.add_argument("--type", dest="feed_type", default="article", choices=["article", "podcast"])
        parser.add_argument("--title", default=None, help="Feed title (auto-detected if omitted)")
        parser.add_argument("--playlist", default=None, help="Default playlist for new items")
        args = parser.parse_args(argv[1:])

        from wilted.feeds import add_feed

        try:
            feed = add_feed(
                args.url,
                feed_type=args.feed_type,
                title=args.title,
                default_playlist=args.playlist,
            )
            print(f"Added feed #{feed.id}: {feed.title} ({feed.feed_type})")
        except ValueError as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)

    elif action == "list":
        from wilted.feeds import list_feeds

        feeds = list_feeds()
        if not feeds:
            print("No feeds configured. Add one with: wilted feed add <url>")
            return

        print(f"Feeds ({len(feeds)}):\n")
        for f in feeds:
            status = "enabled" if f.enabled else "disabled"
            playlist = f" -> {f.default_playlist}" if f.default_playlist else ""
            print(f"  #{f.id}  {f.title} [{f.feed_type}] ({status}){playlist}")
            print(f"       {f.feed_url}")

    elif action == "remove":
        if len(argv) < 2:
            print("Usage: wilted feed remove <id>", file=sys.stderr)
            sys.exit(1)

        from wilted.feeds import remove_feed

        try:
            feed_id = int(argv[1])
            feed = remove_feed(feed_id)
            print(f"Removed feed #{feed_id}: {feed.title}")
        except (ValueError, TypeError) as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)

    elif action == "stats":
        from wilted.report import get_feed_stats

        stats = get_feed_stats()
        if not stats:
            print("No feed statistics available.")
            return

        print("Feed Stats (last 4 weeks):\n")
        for i, stat in enumerate(stats, 1):
            feed_title = stat.get("feed_title", "Unknown")
            discovered = stat.get("items_discovered", 0)
            selected = stat.get("items_selected", 0)
            rate = stat.get("selection_rate")
            rate_percent = f"{rate * 100:.1f}%" if rate is not None else "0.0%"
            print(f"  #{i}  {feed_title}")
            print(f"       Discovered: {discovered}  Selected: {selected}  Rate: {rate_percent}")

    else:
        print(f"Unknown feed action: '{action}'. Use add, list, remove, or stats.", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Phase 2 — Keyword management subcommands
# ---------------------------------------------------------------------------


def cmd_keyword(argv: list[str]) -> None:
    """Dispatch keyword subcommands: add, list, remove."""
    if not argv:
        print("Usage: wilted keyword <add|list|remove> [args]", file=sys.stderr)
        sys.exit(1)

    action = argv[0]

    if action == "add":
        parser = argparse.ArgumentParser(prog="wilted keyword add")
        parser.add_argument("keyword", help="Keyword or phrase")
        parser.add_argument("--weight", type=float, default=1.0, help="Relevance weight (default: 1.0)")
        args = parser.parse_args(argv[1:])

        from wilted.preferences import add_keyword

        try:
            kw = add_keyword(args.keyword, weight=args.weight)
            print(f"Added keyword: '{kw.keyword}' (weight: {kw.weight:.1f})")
        except ValueError as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)

    elif action == "list":
        from wilted.preferences import list_keywords

        keywords = list_keywords()
        if not keywords:
            print("No keywords configured. Add one with: wilted keyword add <word>")
            return

        print(f"Keywords ({len(keywords)}):\n")
        for kw in keywords:
            print(f"  {kw.keyword} (weight: {kw.weight:.1f})")

    elif action == "remove":
        if len(argv) < 2:
            print("Usage: wilted keyword remove <keyword>", file=sys.stderr)
            sys.exit(1)

        from wilted.preferences import remove_keyword

        keyword = " ".join(argv[1:])  # Support multi-word keywords
        try:
            remove_keyword(keyword)
            print(f"Removed keyword: '{keyword}'")
        except ValueError as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)

    else:
        print(f"Unknown keyword action: '{action}'. Use add, list, or remove.", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Phase 2 — Playlist management subcommands
# ---------------------------------------------------------------------------


def cmd_playlist(argv: list[str]) -> None:
    """Dispatch playlist subcommands: list, create, delete, add, remove."""
    if not argv:
        print(
            "Usage: wilted playlist <list|create|delete|add|remove> [args]",
            file=sys.stderr,
        )
        sys.exit(1)

    action = argv[0]

    if action == "list":
        from wilted.playlists import (
            ensure_default_playlists,
            get_playlist_items,
            list_playlists,
        )

        ensure_default_playlists()
        playlists = list_playlists()
        if not playlists:
            print("No playlists found.")
            return

        print(f"Playlists ({len(playlists)}):\n")
        for pl in playlists:
            items = get_playlist_items(pl.name)
            print(f"  {pl.name} [{pl.playlist_type}] — {len(items)} item(s)")

    elif action == "create":
        if len(argv) < 2:
            print("Usage: wilted playlist create <name>", file=sys.stderr)
            sys.exit(1)

        from wilted.playlists import create_playlist

        name = " ".join(argv[1:])
        try:
            pl = create_playlist(name)
            print(f"Created playlist: '{pl.name}'")
        except ValueError as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)

    elif action == "delete":
        if len(argv) < 2:
            print("Usage: wilted playlist delete <name>", file=sys.stderr)
            sys.exit(1)

        from wilted.playlists import delete_playlist

        name = " ".join(argv[1:])
        try:
            delete_playlist(name)
            print(f"Deleted playlist: '{name}'")
        except ValueError as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)

    elif action == "add":
        if len(argv) < 3:
            print(
                "Usage: wilted playlist add <playlist_name> <item_id> [position]",
                file=sys.stderr,
            )
            sys.exit(1)

        from wilted.playlists import add_to_playlist

        playlist_name = argv[1]
        try:
            item_id = int(argv[2])
            position = int(argv[3]) if len(argv) >= 4 else None
            add_to_playlist(playlist_name, item_id, position=position)
            print(f"Added item #{item_id} to playlist '{playlist_name}'")
        except ValueError as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)

    elif action == "remove":
        if len(argv) < 3:
            print(
                "Usage: wilted playlist remove <playlist_name> <item_id>",
                file=sys.stderr,
            )
            sys.exit(1)

        from wilted.playlists import remove_from_playlist

        playlist_name = argv[1]
        try:
            item_id = int(argv[2])
            remove_from_playlist(playlist_name, item_id)
            print(f"Removed item #{item_id} from playlist '{playlist_name}'")
        except ValueError as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)

    else:
        print(
            f"Unknown playlist action: '{action}'. Use list, create, delete, add, or remove.",
            file=sys.stderr,
        )
        sys.exit(1)


# ---------------------------------------------------------------------------
# Phase 2 — Pipeline subcommands
# ---------------------------------------------------------------------------


def cmd_discover(argv: list[str]) -> None:
    """Run the discovery stage: poll feeds, dedup, fetch articles."""
    from wilted.discover import run_discover

    try:
        stats = run_discover()
        print(f"Discovery complete: {stats['discovered']} new items from {stats['feeds_polled']} feeds")
        if stats["errors"]:
            print(f"  {stats['errors']} feed(s) had errors (see /tmp/wilted.log)")
    except Exception as e:
        print(f"Discovery failed: {e}", file=sys.stderr)
        sys.exit(1)


def cmd_classify(argv: list[str]) -> None:
    """Run the classification stage: categorize, score, summarize fetched items."""
    from wilted.classify import run_classify

    try:
        stats = run_classify()
        print(f"Classification complete: {stats['classified']} items classified")
        if stats["errors"]:
            print(f"  {stats['errors']} item(s) had errors (see /tmp/wilted.log)")
    except Exception as e:
        print(f"Classification failed: {e}", file=sys.stderr)
        sys.exit(1)


def _load_email_config() -> dict:
    """Load email config from wilted.toml. Returns {'enabled': bool, 'to': str}."""
    import tomllib

    from wilted import PROJECT_ROOT

    defaults: dict = {"enabled": False, "to": ""}
    config_path = PROJECT_ROOT / "wilted.toml"
    if not config_path.exists():
        return defaults

    with open(config_path, "rb") as f:
        data = tomllib.load(f)

    email_section = data.get("email", {})
    return {
        "enabled": bool(email_section.get("enabled", False)),
        "to": str(email_section.get("to", "")),
    }


def cmd_report(argv: list[str]) -> None:
    """Generate the morning report from classified items."""
    from wilted.report import get_report, run_report

    parser = argparse.ArgumentParser(prog="wilted report", add_help=False)
    parser.add_argument("--email", action="store_true", default=False)
    args, _ = parser.parse_known_args(argv)

    try:
        run_report()

        if args.email:
            from wilted.report import format_report_email

            result = format_report_email()
            if result is None:
                print("No report to email.")
                return

            subject, body = result
            config = _load_email_config()
            if not config["enabled"] or not config["to"]:
                print("Email not configured. Set [email] enabled=true and to=... in wilted.toml")
                return

            subprocess.run(
                [
                    os.path.expanduser("~/.agent/bin/email-alert"),
                    "--subject",
                    subject,
                    "--to",
                    config["to"],
                ],
                input=body,
                text=True,
                check=True,
            )
            print(f"Report emailed to {config['to']}.")
            return

        report_data = get_report()

        if report_data is None:
            print("No report available. Run discovery and classification first.")
            return

        report = report_data["report"]
        report_date = report["report_date"]
        items_dict = report_data["items"]

        print(f"Morning report for {report_date}:")

        total_items = 0
        for playlist, items in sorted(items_dict.items()):
            item_count = len(items)
            total_items += item_count
            playlist_header = f"  {playlist} ({item_count} items):"
            print(playlist_header)
            for item in items:
                score = item.get("relevance_score")
                score_str = f"[{score:.2f}]" if score is not None else "[N/A]"
                title = item.get("title", "Untitled")
                summary = item.get("summary", "")
                if len(title) > 60:
                    title = title[:57] + "..."
                if summary:
                    summary_preview = summary[:40] + "..." if len(summary) > 40 else summary
                    print(f"    {score_str} {title} — {summary_preview}")
                else:
                    print(f"    {score_str} {title}")

        # Count unique feeds
        feed_ids = set()
        for playlist, items in items_dict.items():
            for item in items:
                if item.get("feed_id"):
                    feed_ids.add(item["feed_id"])

        print(f"Total: {total_items} items from {len(feed_ids)} feeds")

    except Exception as e:
        print(f"Report generation failed: {e}", file=sys.stderr)
        sys.exit(1)


def cmd_benchmark(argv: list[str]) -> None:
    """Run LLM benchmarking for classification tasks."""
    if not argv:
        print("Usage: wilted benchmark classify --models 'model1,model2'", file=sys.stderr)
        sys.exit(1)

    task = argv[0]
    if task != "classify":
        print(f"Unknown benchmark task: '{task}'. Available: classify", file=sys.stderr)
        sys.exit(1)

    parser = argparse.ArgumentParser(prog="wilted benchmark classify")
    parser.add_argument("--models", required=True, help="Comma-separated list of model identifiers")
    parser.add_argument("--backend", default="mlx", choices=["mlx", "gguf"], help="Backend type (default: mlx)")
    args = parser.parse_args(argv[1:])

    from wilted.classify import run_benchmark

    models = [m.strip() for m in args.models.split(",")]
    try:
        run_benchmark(models=models, backend_type=args.backend)
    except Exception as e:
        print(f"Benchmark failed: {e}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Phase 4 — Content preparation
# ---------------------------------------------------------------------------


def cmd_prepare(argv: list[str]) -> None:
    """Run the content preparation stage for selected items."""
    parser = argparse.ArgumentParser(prog="wilted prepare")
    parser.add_argument("--no-llm", action="store_true", help="Skip LLM-based ad/promo detection")
    parser.add_argument("--model", default="mlx-community/gemma-4-e4b-it-4bit", help="LLM model for ad detection")
    parser.add_argument("--backend", default="mlx", choices=["mlx", "gguf"], help="LLM backend type")
    args = parser.parse_args(argv)

    from wilted.prepare import run_prepare

    try:
        stats = run_prepare(
            use_llm=not args.no_llm,
            llm_model=args.model,
            llm_backend_type=args.backend,
        )
        print(f"Prepare complete: {stats['prepared']} prepared, {stats['errors']} errors")
    except Exception as e:
        print(f"Prepare failed: {e}", file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Onboarding + ingestion
# ---------------------------------------------------------------------------


def cmd_setup(argv: list[str]) -> None:
    """Interactive first-run setup: feeds, keywords, first ingestion."""
    from wilted.onboard import run_setup

    try:
        run_setup()
    except (KeyboardInterrupt, EOFError):
        print("\n\nSetup cancelled.")


def cmd_ingest(argv: list[str]) -> None:
    """Run the full nightly pipeline: discover → classify → report."""
    parser = argparse.ArgumentParser(
        prog="wilted ingest",
        description="Run the content ingestion pipeline.",
    )
    parser.add_argument("--skip-discover", action="store_true", help="Skip feed polling")
    parser.add_argument("--skip-classify", action="store_true", help="Skip LLM classification")
    parser.add_argument("--skip-report", action="store_true", help="Skip report generation")
    args = parser.parse_args(argv)

    from wilted.onboard import run_ingest

    try:
        run_ingest(
            skip_discover=args.skip_discover,
            skip_classify=args.skip_classify,
            skip_report=args.skip_report,
        )
    except KeyboardInterrupt:
        print("\n\nIngestion interrupted.")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Argument parsing and dispatch
# ---------------------------------------------------------------------------


def run_cli(argv=None):
    """Parse CLI arguments and dispatch to the appropriate command.

    Accepts both new subcommand syntax (``wilted list``) and legacy flag
    syntax (``wilted --list``) via :func:`_normalize_argv`.

    Args:
        argv: Argument list to parse. Defaults to sys.argv[1:] if None.
    """
    if argv is None:
        argv = sys.argv[1:]
    argv = list(argv)

    # Route subcommands before argparse.
    if argv:
        first = argv[0]
        if first == "doctor":
            cmd_doctor(argv[1:])
            return
        if first == "migrate":
            from wilted.migrate import cmd_migrate

            cmd_migrate(argv[1:])
            return
        if first == "feed":
            cmd_feed(argv[1:])
            return
        if first == "keyword":
            cmd_keyword(argv[1:])
            return
        if first == "discover":
            cmd_discover(argv[1:])
            return
        if first == "classify":
            cmd_classify(argv[1:])
            return
        if first == "report":
            cmd_report(argv[1:])
            return
        if first == "benchmark":
            cmd_benchmark(argv[1:])
            return
        if first == "prepare":
            cmd_prepare(argv[1:])
            return
        if first == "setup":
            cmd_setup(argv[1:])
            return
        if first == "ingest":
            cmd_ingest(argv[1:])
            return
        if first == "playlist":
            cmd_playlist(argv[1:])
            return
        if first in _STUB_SUBCMDS:
            _run_stub(argv)
            return

    # Translate subcommand style → flag style so the flat parser handles both.
    argv = _normalize_argv(argv)

    parser = argparse.ArgumentParser(
        description="Wilted — local TTS article reader. No args launches the TUI.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  wilted                                  Launch interactive TUI
  wilted add https://apple.news/ABC123    Add to reading list (subcommand)
  wilted --add https://apple.news/ABC123  Add to reading list (legacy)
  wilted list                             Show reading list
  wilted play                             Play entire reading list
  wilted --clean URL                      Preview cleaned article text
  wilted --save out.wav URL               Export article audio to WAV""",
    )

    parser.add_argument("input", nargs="?", help="URL, file path, '-' for stdin (CLI mode only)")

    queue_group = parser.add_argument_group("reading list")
    queue_group.add_argument("--add", action="store_true", help="Add article to reading list (from URL or clipboard)")
    queue_group.add_argument("--list", action="store_true", help="Show reading list")
    queue_group.add_argument("--play", action="store_true", help="Play all articles in reading list")
    queue_group.add_argument("--next", action="store_true", help="Play next article in reading list")
    queue_group.add_argument("--remove", type=int, metavar="N", help="Remove article N from reading list")
    queue_group.add_argument("--clear", action="store_true", help="Clear entire reading list")

    play_group = parser.add_argument_group("playback")
    play_group.add_argument("--voice", default="af_heart", help="Voice preset (default: af_heart)")
    play_group.add_argument("--speed", type=float, default=1.0, help="Speech speed 0.5-2.0 (default: 1.0)")
    play_group.add_argument(
        "--model", default="mlx-community/Kokoro-82M-bf16", help="TTS model (default: mlx-community/Kokoro-82M-bf16)"
    )
    play_group.add_argument(
        "--lang", default="a", help="Language: a=American, b=British, j=Japanese, z=Chinese (default: a)"
    )
    play_group.add_argument("--save", metavar="FILE", help="Save audio to file instead of playing")

    util_group = parser.add_argument_group("utility")
    util_group.add_argument("--clean", action="store_true", help="Output cleaned text only, no audio")
    util_group.add_argument("--list-voices", action="store_true", help="List available voices")
    util_group.add_argument("--version", action="store_true", help="Show version and exit")
    util_group.add_argument("--debug", action="store_true", help="Enable DEBUG logging to /tmp/wilted.log")

    args = parser.parse_args(argv)

    try:
        if args.version:
            from wilted import __version__

            print(f"wilted {__version__}")
            return
        if args.list_voices:
            cmd_list_voices()
        elif args.list:
            cmd_list(args)
        elif args.add:
            cmd_add(args)
        elif args.remove is not None:
            cmd_remove(args)
        elif args.clear:
            cmd_clear(args)
        elif args.play:
            cmd_play(args)
        elif args.next:
            cmd_next(args)
        else:
            cmd_direct(args)
    except CLIError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main():
    """Main entry point — dispatches to TUI (no args) or CLI (with args).

    Startup order: logging → project root validation → migrations → tqdm lock → TUI/CLI
    """
    debug = bool(os.environ.get("WILTED_DEBUG")) or "--debug" in sys.argv
    setup_logging(debug=debug)

    validate_project_root()

    from wilted import DATA_DIR
    from wilted.db import run_migrations

    run_migrations(DATA_DIR / "wilted.db")

    from wilted.playlists import ensure_default_playlists

    ensure_default_playlists()

    if len(sys.argv) > 1:
        run_cli()
    else:
        # Pre-initialize tqdm's multiprocessing lock on the main thread.
        # If the first initialization happens inside a Textual worker during
        # Hugging Face snapshot_download(), Python's resource_tracker may spawn
        # a subprocess with invalid pass-through FDs and raise fds_to_keep.
        import tqdm

        tqdm.tqdm.get_lock()

        from wilted.tui import WiltedApp

        WiltedApp().run()
