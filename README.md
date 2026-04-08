# Lilt

Local text-to-speech article reader for macOS, powered by [Kokoro TTS](https://github.com/hexgrad/kokoro) via [mlx-audio](https://github.com/Blaizzy/mlx-audio) on Apple Silicon.

## Install

Requires Python 3.12 (Homebrew).

```bash
python3.12 -m venv ~/.venvs/mlx-audio
~/.venvs/mlx-audio/bin/pip install "mlx-audio[tts]" trafilatura numpy
```

Then install the package (editable) and TUI dependencies:

```bash
cd ~/Documents/Projects/lilt
~/.venvs/mlx-audio/bin/pip install -e ".[tui,test]"
```

Add a shell alias (e.g. in `~/.zshrc`):

```bash
alias lilt='~/Documents/Projects/lilt/lilt'
```

First run downloads the Kokoro model from HuggingFace (~160MB, one-time).

## Quick start

```bash
lilt                              # launch TUI (no args)
lilt --add https://apple.news/... # add article to queue
lilt --list                       # show queue
```

## Reading list

Queue articles for later listening. Text is pre-fetched and cached locally so playback works offline.

```bash
lilt --add https://apple.news/ABC123   # fetch and cache article
lilt --add                              # cache from clipboard
lilt --list                             # show queue with word counts
lilt --next                             # play and remove next article
lilt --play                             # play all, removing as completed
lilt --remove 2                         # drop article #2
lilt --clear                            # empty the queue
```

## Playback options

```bash
lilt --voice am_adam        # male American voice
lilt --voice bf_emma        # female British voice
lilt --speed 1.2            # faster
lilt --speed 0.8            # slower
lilt --lang b               # British English prosody
lilt --save article.wav     # save to file instead of playing
lilt --list-voices          # show all available voices
```

## Utility

```bash
lilt --clean                # preview cleaned text, no audio
lilt --clean > article.txt  # save cleaned text to file
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
2. `lilt --add <paste link>`

The script resolves the `apple.news` URL to the source site and fetches the complete article. Works for non-hard-paywalled content (Atlantic, New Yorker metered articles, Reason, etc.).

For hard-paywalled articles, scroll to the bottom in Apple News first, then Cmd+A > Cmd+C and run `lilt --add`.

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

Running `lilt` with no arguments launches the interactive TUI — a complete replacement for the CLI with visual feedback.

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
lilt                     # thin shim (backward compat with shell alias)
pyproject.toml           # package metadata, [project.scripts] entry point
src/lilt/                # shared library
    __init__.py          # constants, VOICES, LANGUAGES, data paths
    cli.py               # CLI commands and argparse dispatch
    engine.py            # AudioEngine (sounddevice + TTS)
    fetch.py             # URL resolution, text extraction
    queue.py             # reading list persistence
    state.py             # resume state persistence
    cache.py             # audio cache (MP3 storage, manifest)
    text.py              # text cleaning and splitting
    tui.py               # Textual TUI app
tests/                   # 257 tests (pytest)
```

## Roadmap

- ~~Pre-generated audio for instant playback~~ (done: background MP3 caching + hybrid playback)
- Custom RSS feed subscriptions
- Apple Podcast integration (private feed)
- Unified ad-free feed (download existing podcasts, strip ads, merge into private feed)

## Dependencies

- Python 3.12+ (via Homebrew)
- mlx-audio (Apple Silicon TTS framework)
- ffmpeg (required for MP3 audio caching; `brew install ffmpeg`)
- Kokoro TTS model (82M params, downloaded on first use)
- trafilatura (article text extraction)
- numpy
- textual (TUI framework)
- sounddevice (audio playback)
