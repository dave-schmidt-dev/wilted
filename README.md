# Wilted

Local-first personal audio news and entertainment system for macOS, powered by [Kokoro TTS](https://github.com/hexgrad/kokoro) via [mlx-audio](https://github.com/Blaizzy/mlx-audio) on Apple Silicon.

## Vision

Wilted is meant to become the one place to listen to news, podcasts, and learning content throughout the day.

The end state is not just a text-to-speech article reader. It is a personal audio system that:

- pulls in subscribed podcasts and written sources
- converts important articles into listenable audio
- removes friction where possible, including podcast ad stripping
- organizes everything into dynamic playlists such as `Work`, `Fun`, and `Education`
- produces a morning report that summarizes what arrived since yesterday and points to the highest-value items first

The product should feel like a private, local-first listening surface rather than a collection of separate article and podcast tools.

## Install

Requires Python 3.12 and [uv](https://docs.astral.sh/uv/).

```bash
cd ~/Documents/Projects/wilted
uv sync
```

For LLM-based classification (optional):

```bash
uv sync --extra llm
```

Add a shell alias (e.g. in `~/.zshrc`):

```bash
alias wilted='uv run --project ~/Documents/Projects/wilted wilted'
```

This ensures the alias always uses the project's managed venv with all
dependencies (including playwright for browser-based article fetching).

First run downloads the Kokoro model from HuggingFace (~160MB, one-time).

### Development

```bash
uv sync --group dev   # install with dev/test deps
make validate                      # lint + full test suite
```

## Quick start

```bash
wilted                              # launch TUI (no args)
wilted --add https://apple.news/... # add article to queue
wilted --list                       # show queue
```

## Reading list

Queue articles for later listening. Text is pre-fetched and cached locally so playback works offline.

```bash
wilted --add https://apple.news/ABC123   # fetch and cache article
wilted --add                              # cache from clipboard
wilted --list                             # show queue with word counts
wilted --next                             # play and remove next article
wilted --play                             # play all, removing as completed
wilted --remove 2                         # drop article #2
wilted --clear                            # empty the queue
```

## Playback options

```bash
wilted --voice am_adam        # male American voice
wilted --voice bf_emma        # female British voice
wilted --speed 1.2            # faster
wilted --speed 0.8            # slower
wilted --lang b               # British English prosody
wilted --save article.wav     # save to file instead of playing
wilted --list-voices          # show all available voices
```

Speed persists between sessions automatically. In the TUI, `+`/`-` adjusts speed and it is remembered next launch. To set a default speed before first use, add to `wilted.toml`:

```toml
[playback]
speed = 1.3
```

## Utility

```bash
wilted --clean                # preview cleaned text, no audio
wilted --clean > article.txt  # save cleaned text to file
```

## Voices (Kokoro)

| Code | Name | Gender | Accent |
|------|------|--------|--------|
| af_heart | Heart | F | American |
| af_bella | Bella | F | American |
| af_nova | Nova | F | American |
| af_sky | Sky | F | American |
| am_adam | Adam | M | American |
| am_echo | Echo | M | American |
| bf_alice | Alice | F | British |
| bf_emma | Emma | F | British |
| bm_daniel | Daniel | M | British |
| bm_george | George | M | British |

## Apple News workflow

Apple News copy-paste truncates long articles. For full text, use the share link:

1. In Apple News, tap Share > Copy Link
2. `wilted --add <paste link>`

The script resolves the `apple.news` URL to the source site and fetches the complete article. Works for non-hard-paywalled content (Atlantic, New Yorker metered articles, Reason, etc.).

For hard-paywalled articles, scroll to the bottom in Apple News first, then Cmd+A > Cmd+C and run `wilted --add`.

## Product direction

The current implementation is article-first, but the roadmap is broader:

- saved articles and Apple News links flow into the same listening system
- podcast subscriptions should eventually be ingested into Wilted as audio items
- playlists should become the main organizing concept, not just a flat queue
- articles and podcasts should coexist inside shared listening contexts like `Work`, `Fun`, and `Education`
- the daily morning report should become the control surface for deciding what to hear first

## Data

Runtime data stored in `data/` (gitignored):

```
data/
  wilted.db         # SQLite database (WAL mode)
  articles/         # cached article text files
  audio/            # pre-generated MP3 cache (per-article)
```

## TUI

Running `wilted` with no arguments launches the interactive TUI — a complete replacement for the CLI with visual feedback.

The TUI uses the **Salad Palette** — a muted, organic color scheme designed for comfortable reading in a dark terminal:

- **Dark Sea Green** (`#8FBC8F`) — headers, active playback state
- **Sage** (`#A9BA9D`) — secondary text, read paragraphs
- **Cream** (`#F2E8CF`) — current paragraph highlight, focus/selection
- **Muted Red** (`#BC4749`) — stop, delete actions
- **Bright Lime** (`#A7C957`) — new/unread indicators

The queue panel is called **The Larder** and the playback panel is **The Plate**.

### NerdFont icons

The TUI uses standard Unicode icons by default (`▶ ⏸ ● ◐ ○`). If you have a [NerdFont](https://www.nerdfonts.com/)-patched terminal font installed, enable richer icons:

```bash
NERD_FONTS=1 wilted
```

Or add to your shell profile:

```bash
export NERD_FONTS=1
```

### Key bindings

| Key | Action |
|-----|--------|
| `p` / `space` | Play / Pause / Resume |
| `enter` | Expand/collapse tree node (Tree widget native) |
| `]` / `right` | Skip to next paragraph |
| `[` | Rewind to previous paragraph |
| `+` / `=` | Speed up 0.1x |
| `-` | Speed down 0.1x |
| `n` | Next article |
| `m` | Mark selected as read (stays in DB, removed from playlists) |
| `v` | Voice / speed / language settings |
| `a` | Add article (URL or clipboard, with fetch progress) |
| `ctrl+p` | Add article and play immediately |
| `d` | Delete selected permanently (with confirmation) |
| `t` | Text preview of selected article |
| `w` | Export selected article to WAV |
| `c` | Clear all articles (with confirmation) |
| `r` | Refresh queue |
| `q` | Quit (saves resume position) |

Full design: [TUI_PLAN.md](TUI_PLAN.md)

## Project structure

```
wilted                     # thin shim (backward compat with shell alias)
pyproject.toml           # package metadata, [project.scripts] entry point
src/wilted/                # shared library
    __init__.py          # constants, VOICES, LANGUAGES, data paths
    cli.py               # CLI commands and argparse dispatch
    db.py                # Peewee ORM models, migrations, SQLite management
    engine.py            # AudioEngine (sounddevice + TTS)
    fetch.py             # URL resolution, text extraction
    queue.py             # reading list persistence (SQLite-backed)
    cache.py             # audio cache (MP3 storage, manifest)
    text.py              # text cleaning and splitting
    ingest.py            # shared article ingestion
    playlists.py         # playlist CRUD and default-playlist bootstrap
    feeds.py             # feed subscription CRUD
    discover.py          # RSS polling, dedup, article fetch
    classify.py          # LLM-based classification + benchmark
    llm.py               # LLM backend interface (MLX, GGUF)
    preferences.py       # keyword-based relevance scoring
    migrate.py           # queue.json -> SQLite migration
    log.py               # RotatingFileHandler setup
    tui/                 # Textual TUI (decomposed package)
tests/                   # pytest suite (638 tests across unit/integration/e2e/TUI lanes)
migrations/              # numbered schema migrations
```

## Validation

Routine validation uses tiered lanes. The current split is:

- `221` unit tests
- `334` integration tests
- `30` subprocess e2e tests
- `53` TUI tests

Default project validation still uses the guarded fast lane:

```bash
make validate
```

That runs:

- `ruff` linting
- unit/integration tests for CLI, engine, queue/cache, ingest, and TUI behavior
- subprocess e2e tests for CLI commands, feed/keyword CRUD, article lifecycle, and RSS discovery
- ffmpeg MP3 encode/decode round-trip
- TUI launch and quit with real SQLite database
- concurrency guardrails that verify MLX work stays serialized behind `_model_lock`
- startup guardrails that verify `tqdm` lock initialization happens on the main thread before Textual starts

Targeted lanes:

```bash
make test-unit
make test-integration
make test-e2e
make test-tui
```

### Manual playback verification

Automated tests cover everything up to `sounddevice.OutputStream.write()`. Actual speaker output requires manual verification:

```bash
wilted --add https://example.com/article    # add a real article
wilted --next                                # play it — verify audio from speakers
```

In the TUI (`wilted` with no args):
1. Press `a` to add an article
2. Press `enter` to play — verify audio
3. Press `space` to pause/resume — verify it resumes at the right spot
4. Press `]` to skip paragraph — verify next paragraph plays
5. Press `s` to stop
6. Press `q` to quit

### What to avoid in future

- Do not add in-process tests that import or execute real MLX/Metal work inside the pytest runner.
- Do not add standalone MLX/Metal diagnostic probes whose only purpose is to stress the native stack rather than validate Wilted behavior.
- Do not rely on collection-time `sys.modules` stubs; keep native-module fakes inside fixtures or test-local patch scopes.
- Do not bypass `_model_lock` for `load_model()`, `generate_audio()`, `generate_and_play()`, or `play_article()`.
- Do not let lazy MLX generators escape the lock before converting segment audio to NumPy.
- Do not let the first `tqdm` lock initialization happen inside a Textual worker thread.

## Feed management

Subscribe to RSS/Atom feeds for automatic content discovery:

```bash
wilted feed add https://example.com/feed.xml --type article --playlist Work
wilted feed add https://example.com/pod.xml --type podcast --playlist Fun
wilted feed list
wilted feed remove 3
```

Run the nightly pipeline stages:

```bash
wilted discover              # poll feeds, fetch articles, dedup
wilted classify              # categorize, score, summarize (requires MLX LLM)
wilted benchmark classify --models "model1,model2"  # compare classification models
```

Manage relevance keywords:

```bash
wilted keyword add "kubernetes" --weight 1.5
wilted keyword list
wilted keyword remove "kubernetes"
```

## Playlist management

Playlists organize content into listening contexts. Dynamic playlists (All, Work, Fun, Education) are created automatically. Static playlists are user-created.

```bash
wilted playlist list                               # show all playlists with item counts
wilted playlist create "My Reading List"           # create static playlist
wilted playlist delete "My Reading List"           # delete static (not dynamic)
wilted playlist add "My Reading List" <item_id>    # add item to static playlist
wilted playlist remove "My Reading List" <item_id> # remove from static playlist
```

## Email reports

Configure email delivery of the morning report:

1. Install [email-alerts](https://github.com/dave-schmidt-dev/email-alerts) and set `GMAIL_USER` / `GMAIL_APP_PASSWORD`
2. Create `wilted.toml` in the project root:
```toml
[email]
enabled = true
to = "you@example.com"
```
3. Send manually: `wilted report --email`
4. Or install the nightly schedule: `make install-launchd`

## Roadmap

- Near term:
  - unified content model (articles + podcasts + playlists in one schema)
  - playlist rules (assignment, override, decay)
- Content preparation (Phase 4):
  - podcast audio download and transcription (RSS ingest + local fallback)
  - ad detection with sliding window + ffmpeg cutting
  - article promotional content removal
  - article TTS generation for pipeline items
- Radio mode (Phase 6):
  - always-on continuous playback that fills airtime from queue, feeds, and discovered content
  - priority interrupts for breaking/important stories, then resume where you left off
  - regular feed scanning (every ~15 min) with importance detection
  - auto-fill when queue is empty — prefer subscribed feeds, allow broader discovery
  - time-of-day awareness — morning news, midday light, evening education/entertainment
- ~~Pre-generated audio for instant playback~~ (done: background MP3 caching + hybrid playback)
- ~~RSS feed management~~ (done: feed CRUD, RSS polling, dedup, conditional GET)
- ~~LLM classification~~ (done: playlist assignment, relevance scoring, summarization)
- ~~Morning report~~ (done: report assembly, TUI ReportScreen, selection history, source stats, `wilted report` + `wilted feed stats`)
- ~~Playlists + Polish (Phase 5)~~ (done: dynamic/static playlists, CLI `wilted playlist`, `ensure_default_playlists` on startup, email morning report, nightly wrapper script, launchd integration. 660 tests green.)
- ~~E2e test coverage + playback verification~~ (done: tiered suite with 580 app-facing tests, plus manual speaker verification)

## Dependencies

- Python 3.12+ (via Homebrew)
- mlx-audio (Apple Silicon TTS framework)
- ffmpeg (required for MP3 audio caching; `brew install ffmpeg`)
- Kokoro TTS model (82M params, downloaded on first use)
- trafilatura (article text extraction)
- peewee (SQLite ORM)
- feedparser (RSS/Atom parsing)
- numpy
- textual (TUI framework)
- sounddevice (audio playback)
