"""End-to-end tests — run wilted as a subprocess to verify real CLI behavior.

These tests exercise the real entry point, real database, and real argument
parsing without mocks.  Each test gets an isolated WILTED_PROJECT_ROOT so
there is no interference with the user's data or between tests.

The only thing NOT tested here is actual audio playback (requires a sound
device) and real TTS generation (requires the MLX model).
"""

import http.server
import os
import subprocess
import sys
import threading

import pytest

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def wilted_home(tmp_path):
    """Isolated project root with the minimum marker file."""
    (tmp_path / "pyproject.toml").write_text('[project]\nname = "wilted"\n')
    env = os.environ.copy()
    env["WILTED_PROJECT_ROOT"] = str(tmp_path)
    return tmp_path, env


def _run(*args, env, input_text=None, timeout=30):
    """Run wilted CLI as a fresh subprocess."""
    return subprocess.run(
        [
            sys.executable,
            "-c",
            "import sys; sys.argv[0] = 'wilted'; from wilted.cli import main; main()",
            *args,
        ],
        capture_output=True,
        text=True,
        env=env,
        input=input_text,
        timeout=timeout,
    )


# ---------------------------------------------------------------------------
# Basic CLI commands
# ---------------------------------------------------------------------------


class TestCLIBasics:
    def test_version(self, wilted_home):
        _, env = wilted_home
        r = _run("--version", env=env)
        assert r.returncode == 0
        assert "wilted" in r.stdout

    def test_list_empty(self, wilted_home):
        _, env = wilted_home
        r = _run("--list", env=env)
        assert r.returncode == 0
        assert "empty" in r.stdout.lower()

    def test_list_voices(self, wilted_home):
        _, env = wilted_home
        r = _run("--list-voices", env=env)
        assert r.returncode == 0
        assert "af_heart" in r.stdout
        assert "American" in r.stdout

    def test_doctor(self, wilted_home):
        tmp_path, env = wilted_home
        r = _run("doctor", env=env)
        assert r.returncode == 0
        assert str(tmp_path) in r.stdout
        assert "pyproject" in r.stdout

    def test_clear_empty(self, wilted_home):
        _, env = wilted_home
        r = _run("--clear", env=env)
        assert r.returncode == 0
        assert "empty" in r.stdout.lower()

    def test_remove_invalid_index(self, wilted_home):
        _, env = wilted_home
        r = _run("--remove", "1", env=env)
        assert r.returncode == 1


# ---------------------------------------------------------------------------
# Text processing (no network, no audio)
# ---------------------------------------------------------------------------


class TestTextProcessing:
    def test_clean_from_file(self, wilted_home):
        tmp_path, env = wilted_home
        article = tmp_path / "article.txt"
        article.write_text("This is a test article.\n\nWith two paragraphs.")
        r = _run("--clean", str(article), env=env)
        assert r.returncode == 0
        assert "test article" in r.stdout

    def test_clean_from_stdin(self, wilted_home):
        _, env = wilted_home
        r = _run("--clean", "-", env=env, input_text="This is piped text for testing.")
        assert r.returncode == 0
        assert "piped text" in r.stdout


# ---------------------------------------------------------------------------
# Feed lifecycle
# ---------------------------------------------------------------------------


class TestFeedLifecycle:
    def test_feed_list_empty(self, wilted_home):
        _, env = wilted_home
        r = _run("feed", "list", env=env)
        assert r.returncode == 0
        assert "No feeds" in r.stdout

    def test_feed_add_list_remove(self, wilted_home):
        _, env = wilted_home

        # Add
        r = _run("feed", "add", "https://example.com/feed.xml", env=env)
        assert r.returncode == 0
        assert "Added feed" in r.stdout

        # List
        r = _run("feed", "list", env=env)
        assert r.returncode == 0
        assert "example.com" in r.stdout

        # Remove
        r = _run("feed", "remove", "1", env=env)
        assert r.returncode == 0
        assert "Removed" in r.stdout

        # Verify gone
        r = _run("feed", "list", env=env)
        assert "No feeds" in r.stdout

    def test_feed_add_with_options(self, wilted_home):
        _, env = wilted_home
        r = _run(
            "feed",
            "add",
            "https://example.com/pod.xml",
            "--type",
            "podcast",
            "--playlist",
            "Fun",
            env=env,
        )
        assert r.returncode == 0
        assert "podcast" in r.stdout

        r = _run("feed", "list", env=env)
        assert "podcast" in r.stdout
        assert "Fun" in r.stdout

    def test_feed_add_duplicate(self, wilted_home):
        _, env = wilted_home
        _run("feed", "add", "https://example.com/feed.xml", env=env)
        r = _run("feed", "add", "https://example.com/feed.xml", env=env)
        assert r.returncode == 1  # duplicate should fail


# ---------------------------------------------------------------------------
# Keyword lifecycle
# ---------------------------------------------------------------------------


class TestKeywordLifecycle:
    def test_keyword_list_empty(self, wilted_home):
        _, env = wilted_home
        r = _run("keyword", "list", env=env)
        assert r.returncode == 0
        assert "No keywords" in r.stdout

    def test_keyword_add_list_remove(self, wilted_home):
        _, env = wilted_home

        # Add
        r = _run("keyword", "add", "kubernetes", "--weight", "1.5", env=env)
        assert r.returncode == 0
        assert "kubernetes" in r.stdout
        assert "1.5" in r.stdout

        # List
        r = _run("keyword", "list", env=env)
        assert r.returncode == 0
        assert "kubernetes" in r.stdout

        # Remove
        r = _run("keyword", "remove", "kubernetes", env=env)
        assert r.returncode == 0
        assert "Removed" in r.stdout

        # Verify gone
        r = _run("keyword", "list", env=env)
        assert "No keywords" in r.stdout


# ---------------------------------------------------------------------------
# Article lifecycle (local HTTP server)
# ---------------------------------------------------------------------------


_TEST_HTML = """\
<html><head><title>Test Article</title></head>
<body><article>
<p>This is a test article with enough words to be meaningful.
It has multiple sentences so the text extraction can find something useful.
The wilted system should be able to fetch and cache this article text
for later playback through the TTS engine.</p>
</article></body></html>"""


class _QuietHandler(http.server.BaseHTTPRequestHandler):
    """Serve _TEST_HTML on any GET; suppress request logs."""

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(_TEST_HTML.encode())

    def log_message(self, *_args):
        pass


@pytest.fixture()
def local_server():
    """Start a throwaway HTTP server on localhost."""
    server = http.server.HTTPServer(("127.0.0.1", 0), _QuietHandler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{port}"
    server.shutdown()


class TestArticleLifecycle:
    def test_add_list_remove(self, wilted_home, local_server):
        _, env = wilted_home

        # Add
        r = _run("--add", f"{local_server}/article", env=env)
        assert r.returncode == 0
        assert "Added" in r.stdout

        # List
        r = _run("--list", env=env)
        assert r.returncode == 0
        assert "1" in r.stdout  # at least article #1

        # Remove
        r = _run("--remove", "1", env=env)
        assert r.returncode == 0
        assert "Removed" in r.stdout

        # Verify empty
        r = _run("--list", env=env)
        assert "empty" in r.stdout.lower()

    def test_add_multiple_then_clear(self, wilted_home, local_server):
        _, env = wilted_home

        _run("--add", f"{local_server}/a1", env=env)
        _run("--add", f"{local_server}/a2", env=env)

        r = _run("--clear", env=env)
        assert r.returncode == 0
        assert "Cleared 2" in r.stdout

        r = _run("--list", env=env)
        assert "empty" in r.stdout.lower()


# ---------------------------------------------------------------------------
# Discovery pipeline
# ---------------------------------------------------------------------------


_RSS_TEMPLATE = """\
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Test Feed</title>
    <link>{base}/</link>
    <description>A test RSS feed for e2e testing</description>
    <item>
      <title>First Test Article</title>
      <link>{base}/article/1</link>
      <guid>urn:test:article:1</guid>
      <description>Summary of first article</description>
    </item>
    <item>
      <title>Second Test Article</title>
      <link>{base}/article/2</link>
      <guid>urn:test:article:2</guid>
      <description>Summary of second article</description>
    </item>
  </channel>
</rss>"""

_ARTICLE_HTML_TEMPLATE = """\
<html><head><title>Article {n}</title></head>
<body><article>
<p>This is test article number {n} served from the local RSS feed server.
It contains enough text for trafilatura to extract a meaningful body.
The wilted discovery pipeline should fetch this via the link in the RSS entry
and store it as a transcript file in the data directory.</p>
</article></body></html>"""


@pytest.fixture()
def rss_server():
    """HTTP server that serves an RSS feed at /feed.xml and articles at /article/<n>."""
    allocated_port = None

    class _RSSHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            base = f"http://127.0.0.1:{allocated_port}"
            if self.path == "/feed.xml":
                body = _RSS_TEMPLATE.format(base=base).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/rss+xml; charset=utf-8")
            elif self.path.startswith("/article/"):
                n = self.path.split("/")[-1]
                body = _ARTICLE_HTML_TEMPLATE.format(n=n).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
            else:
                self.send_response(404)
                body = b"Not found"
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), _RSSHandler)
    allocated_port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{allocated_port}"
    server.shutdown()


class TestDiscovery:
    def test_discover_no_feeds(self, wilted_home):
        _, env = wilted_home
        r = _run("discover", env=env)
        assert r.returncode == 0
        assert "0 new items" in r.stdout
        assert "0 feeds" in r.stdout

    def test_discover_polls_local_rss_feed(self, wilted_home, rss_server):
        """Add a feed pointing at a local RSS server, run discover, verify items created."""
        _, env = wilted_home

        # Register the feed
        r = _run("feed", "add", f"{rss_server}/feed.xml", "--type", "article", env=env)
        assert r.returncode == 0

        # Run discovery — should poll the feed and fetch the article
        r = _run("discover", env=env)
        assert r.returncode == 0
        assert "1 new items" in r.stdout or "2 new items" in r.stdout
        assert "1 feeds" in r.stdout

    def test_discover_dedup_skips_seen_entries(self, wilted_home, rss_server):
        """Running discover twice should not duplicate items."""
        _, env = wilted_home

        _run("feed", "add", f"{rss_server}/feed.xml", "--type", "article", env=env)

        r1 = _run("discover", env=env)
        assert r1.returncode == 0

        # Second run — same entries should be deduped
        r2 = _run("discover", env=env)
        assert r2.returncode == 0
        assert "0 new items" in r2.stdout


# ---------------------------------------------------------------------------
# Report generation
# ---------------------------------------------------------------------------


@pytest.fixture()
def database_with_classified_items(wilted_home):
    """Create a database with classified items for report testing."""
    import os

    tmp_path, env = wilted_home
    # Set WILTED_PROJECT_ROOT for the test process to manipulate the DB
    os.environ["WILTED_PROJECT_ROOT"] = str(tmp_path)

    # Now we can import and manipulate the database
    from datetime import UTC, datetime

    from wilted import DATA_DIR
    from wilted.db import Feed, Item, connect_db, run_migrations

    # Initialize the database
    db_path = DATA_DIR / "wilted.db"
    connect_db(db_path)
    run_migrations(db_path)

    # Create a feed
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    feed = Feed.create(
        title="Test Feed",
        feed_url="https://example.com/test.xml",
        feed_type="article",
        enabled=True,
        created_at=now,
        updated_at=now,
    )

    # Create classified items
    items = [
        ("Work Item 1", "Work", 0.95),
        ("Work Item 2", "Work", 0.85),
        ("Fun Item 1", "Fun", 0.75),
    ]
    for title, playlist, score in items:
        Item.create(
            feed=feed,
            guid=f"test-{title}",
            title=title,
            discovered_at=now,
            item_type="article",
            status="classified",
            status_changed_at=now,
            playlist_assigned=playlist,
            relevance_score=score,
            summary=f"Summary of {title}",
        )

    return tmp_path, env


class TestReport:
    def test_report_no_items(self, wilted_home):
        """Report with no classified items shows empty state."""
        _, env = wilted_home
        r = _run("report", env=env)
        assert r.returncode == 0
        assert "Morning report" in r.stdout
        assert "Total: 0 items" in r.stdout

    def test_report_with_classified_items(self, database_with_classified_items):
        """Report shows classified items grouped by playlist."""
        tmp_path, env = database_with_classified_items
        r = _run("report", env=env)
        assert r.returncode == 0
        assert "Morning report" in r.stdout
        assert "Work" in r.stdout
        assert "Fun" in r.stdout
        assert "Total: 3 items" in r.stdout

    def test_report_idempotent(self, database_with_classified_items):
        """Running report twice produces consistent output."""
        tmp_path, env = database_with_classified_items

        r1 = _run("report", env=env)
        r2 = _run("report", env=env)

        assert r1.returncode == 0
        assert r2.returncode == 0
        # Both should have the same date
        assert "Morning report for" in r1.stdout
        assert "Morning report for" in r2.stdout
        assert r1.stdout == r2.stdout
