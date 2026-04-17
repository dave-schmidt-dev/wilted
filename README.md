# Wilted

Local-first personal audio news and entertainment system for macOS, powered by [Kokoro TTS](https://github.com/hexgrad/kokoro) via [mlx-audio](https://github.com/Blaizzy/mlx-audio) on Apple Silicon.

## Vision

Wilted is meant to become the one place to listen to news, podcasts, and learning content throughout the day.

The end state is not just a text-to-speech article reader. It is a personal audio system that:

- pulls in subscribed podcasts and written sources
- converts important articles into listenable audio
- removes friction where possible, including podcast ad stripping
- organizes everything into dynamic playlists such as `News`, `Entertainment`, and `Learning`
- produces a morning report that summarizes what arrived since yesterday and points to the highest-value items first

The product should feel like a private, local-first listening surface rather than a collection of separate article and podcast tools.

## Install

Requires Python 3.12 (Homebrew).

```bash
python3.12 -m venv ~/.venvs/mlx-audio
~/.venvs/mlx-audio/bin/pip install "mlx-audio[tts]" trafilatura numpy
```

Then install the package (editable) and TUI dependencies:

```bash
cd ~/Documents/Projects/wilted
~/.venvs/mlx-audio/bin/pip install -e ".[tui,test]"
```

Add a shell alias (e.g. in `~/.zshrc`):

```bash
alias wilted='~/.venvs/mlx-audio/bin/wilted'
```

First run downloads the Kokoro model from HuggingFace (~160MB, one-time).

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
- articles and podcasts should coexist inside shared listening contexts like `News`, `Entertainment`, and `Learning`
- the daily morning report should become the control surface for deciding what to hear first

## Data

Runtime data stored in `data/` (gitignored):

```
data/
  queue.json        # reading list metadata
  state.json        # TUI resume positions
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
| `space` | Play / Pause / Resume |
| `s` | Stop playback |
| `enter` | Play selected article |
| `]` / `right` | Skip to next paragraph |
| `[` | Rewind to previous paragraph |
| `+` / `=` | Speed up 0.1x |
| `-` | Speed down 0.1x |
| `n` | Next article |
| `v` | Voice / speed / language settings |
| `a` | Add article (URL or clipboard, with fetch progress) |
| `ctrl+p` | Add article and play immediately |
| `d` | Delete selected (with confirmation) |
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
    engine.py            # AudioEngine (sounddevice + TTS)
    fetch.py             # URL resolution, text extraction
    queue.py             # reading list persistence
    state.py             # resume state persistence
    cache.py             # audio cache (MP3 storage, manifest)
    text.py              # text cleaning and splitting
    tui.py               # Textual TUI app
tests/                   # pytest suite covering CLI, engine, TUI, ingest, cache, and guardrail tests
```

## Validation

Routine validation uses only the guarded code paths that Wilted actually relies on:

```bash
make validate
```

That runs:

- `ruff` linting
- unit/integration tests for CLI, engine, queue/cache, ingest, and TUI behavior
- concurrency guardrails that verify MLX work stays serialized behind `_model_lock`
- startup guardrails that verify `tqdm` lock initialization happens on the main thread before Textual starts

What to avoid in future:

- Do not add in-process tests that import or execute real MLX/Metal work inside the pytest runner.
- Do not add “native smoke” tests to the default validation path just to probe known-bad runtime behavior.
- Do not bypass `_model_lock` for `load_model()`, `generate_audio()`, `generate_and_play()`, or `play_article()`.
- Do not let lazy MLX generators escape the lock before converting segment audio to NumPy.
- Do not let the first `tqdm` lock initialization happen inside a Textual worker thread.

## Roadmap

- Near term:
  - CI/local validation parity for lint + guarded tests
  - packaging/install pass on the supported Python + venv path
  - manual real-device playback verification
- Unified ingest:
  - RSS/article feed data model and persistence
  - feed polling, dedupe, and queue import
  - CLI/TUI feed management
  - podcast subscription import, likely via private feeds or exported subscription sources
- Unified content model:
  - normalize articles and podcasts into one listenable item model
  - support playlists such as `News`, `Entertainment`, and `Learning`
  - allow playlists to build up and break down dynamically based on freshness, source, and priority
- Listening intelligence:
  - article ranking and source selection for major news sources
  - morning report summarizing what arrived since yesterday
  - direct jump targets so the most interesting articles or podcast episodes can be played first
  - ad stripping / enrichment pipeline where feasible and legally safe
- ~~Pre-generated audio for instant playback~~ (done: background MP3 caching + hybrid playback)

## Dependencies

- Python 3.12+ (via Homebrew)
- mlx-audio (Apple Silicon TTS framework)
- ffmpeg (required for MP3 audio caching; `brew install ffmpeg`)
- Kokoro TTS model (82M params, downloaded on first use)
- trafilatura (article text extraction)
- numpy
- textual (TUI framework)
- sounddevice (audio playback)
