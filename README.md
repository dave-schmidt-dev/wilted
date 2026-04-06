# readarticle

Local text-to-speech article reader for macOS, powered by [Kokoro TTS](https://github.com/hexgrad/kokoro) via [mlx-audio](https://github.com/Blaizzy/mlx-audio) on Apple Silicon.

## Install

Requires Python 3.12 (Homebrew).

```bash
python3.12 -m venv ~/.venvs/mlx-audio
~/.venvs/mlx-audio/bin/pip install "mlx-audio[tts]" trafilatura numpy
```

The script lives at `~/.local/bin/readarticle` (already in PATH via `~/.local/bin`).

First run downloads the Kokoro model from HuggingFace (~160MB, one-time).

## Quick start

```bash
# Copy article text, then:
readarticle

# Or pass a URL (supports Apple News share links):
readarticle https://apple.news/ABC123
readarticle https://www.theatlantic.com/some-article/
```

## Reading list

Queue articles for later listening. Text is pre-fetched and cached locally so playback works offline.

```bash
readarticle --add https://apple.news/ABC123   # fetch and cache article
readarticle --add                              # cache from clipboard
readarticle --list                             # show queue with word counts
readarticle --next                             # play and remove next article
readarticle --play                             # play all, removing as completed
readarticle --remove 2                         # drop article #2
readarticle --clear                            # empty the queue
```

## Playback options

```bash
readarticle --voice am_adam        # male American voice
readarticle --voice bf_emma        # female British voice
readarticle --speed 1.2            # faster
readarticle --speed 0.8            # slower
readarticle --lang b               # British English prosody
readarticle --save article.wav     # save to file instead of playing
readarticle --list-voices          # show all available voices
```

## Utility

```bash
readarticle --clean                # preview cleaned text, no audio
readarticle --clean > article.txt  # save cleaned text to file
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
2. `readarticle --add <paste link>`

The script resolves the `apple.news` URL to the source site and fetches the complete article. Works for non-hard-paywalled content (Atlantic, New Yorker metered articles, Reason, etc.).

For hard-paywalled articles, scroll to the bottom in Apple News first, then Cmd+A > Cmd+C and run `readarticle --add`.

## Data

Cached articles and queue metadata are stored in:

```
~/.local/share/readarticle/
  queue.json        # reading list metadata
  articles/         # cached article text files
```

## Roadmap

A Textual TUI (`readarticle-tui`) is planned with interactive playback controls, pause/resume, skip, voice/speed settings, and resume support. Full plan: [TUI_PLAN.md](TUI_PLAN.md)

Future features include:
- Pre-generated audio for instant playback
- Custom RSS feed subscriptions
- Apple Podcast integration (private feed)

## Dependencies

- Python 3.12 (via Homebrew)
- mlx-audio (Apple Silicon TTS framework)
- Kokoro TTS model (82M params, downloaded on first use)
- trafilatura (article text extraction)
- numpy
- afplay (macOS built-in audio player)
