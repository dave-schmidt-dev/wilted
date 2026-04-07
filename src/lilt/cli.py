"""CLI commands for lilt — extracted from the root lilt script for testability."""

import argparse
import os
import sys

from lilt import VOICES, WPM_ESTIMATE
from lilt.fetch import get_text_from_clipboard, get_text_from_url
from lilt.ingest import resolve_article
from lilt.queue import add_article, clear_queue, get_article_text, load_queue, mark_completed, remove_article
from lilt.text import clean_text


class CLIError(Exception):
    """Raised by CLI commands to signal a user-facing error."""


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
        added = entry.get("added", "")[:10]
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
    from lilt.engine import AudioEngine

    word_count = len(text.split())
    est_minutes = word_count / WPM_ESTIMATE
    print(f"  {word_count} words, ~{est_minutes:.0f} min listen time")

    engine = AudioEngine(model_name=args.model, voice=args.voice, speed=args.speed, lang=args.lang)

    if args.save:
        from lilt.engine import export_to_wav
        from lilt.text import split_into_chunks

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
        from lilt.text import split_paragraphs

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
        print("Reading list is empty. Add articles with: lilt --add URL")
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
        print("Reading list is empty. Add articles with: lilt --add URL")
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
                raise CLIError("Could not extract article text (paywall?). Try: lilt --add")
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


# ---------------------------------------------------------------------------
# Argument parsing and dispatch
# ---------------------------------------------------------------------------


def run_cli(argv=None):
    """Parse CLI arguments and dispatch to the appropriate command.

    Args:
        argv: Argument list to parse. Defaults to sys.argv[1:] if None.
    """
    parser = argparse.ArgumentParser(
        description="Lilt — local TTS article reader. No args launches the TUI.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""examples:
  lilt                                  Launch interactive TUI
  lilt --add https://apple.news/ABC123  Add to reading list
  lilt --add                            Add clipboard to reading list
  lilt --list                           Show reading list
  lilt --play                           Play entire reading list
  lilt --next                           Play next article only
  lilt --clean URL                      Preview cleaned article text
  lilt --save out.wav URL               Export article audio to WAV""",
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

    args = parser.parse_args(argv)

    try:
        if args.version:
            from lilt import __version__

            print(f"lilt {__version__}")
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
    """Main entry point — dispatches to TUI (no args) or CLI (with args)."""
    if len(sys.argv) > 1:
        run_cli()
    else:
        from lilt.tui import LiltApp

        LiltApp().run()
