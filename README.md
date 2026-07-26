# Wilted

Local-first personal audio news and entertainment system for macOS, with speech synthesis provided by the local speech-stack daemon on Apple Silicon.

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

The project lives under `~/Documents/`, which iCloud Drive syncs. iCloud sets the
macOS `UF_HIDDEN` flag on `.venv` contents, and Python 3.13's `site.py` silently
skips hidden `.pth` files — which breaks the editable install (see BUG-3 in
`BUGS.md`). The fix is to keep the venv **outside** iCloud via
`UV_PROJECT_ENVIRONMENT`:

```bash
cd ~/Documents/Projects/wilted
export UV_PROJECT_ENVIRONMENT="$HOME/.venvs/wilted"
uv sync
```

Classification and ad detection are core features and run the Gemma-4 E4B QAT (Q4_0) GGUF via
llama.cpp (`llama-cpp-python`). By default, the repaired model file is served from the machine-wide
model store at `~/models/gemma-4-repaired/gemma-4-E4B_q4_0-it-2026-07-15-repaired.gguf` (override the
parent directory via `LOCAL_MODELS_DIR`). The affected upstream GGUF is never used as an automatic
fallback because its duplicate tokenizer entries fail during llama.cpp loading.

### Default GGUF model setup

Model files are intentionally not committed. Given a local copy of the affected E4B source GGUF,
create the validated repaired default without modifying the source:

```bash
OUT="$HOME/models/gemma-4-repaired"
mkdir -p "$OUT"
uv run python -m wilted.gguf_repair --variant e4b \
  /path/to/gemma-4-E4B_q4_0-it.gguf \
  "$OUT/gemma-4-E4B_q4_0-it-2026-07-15-repaired.gguf"
```

The repair command validates the exact model identity, tokenizer defect, metadata layout, and tensor
bytes before publishing the destination. If the repaired default is absent, Wilted fails before model
loading with this setup reference. Alternatively, pass `--backend mlx --model <hf-repo>` to use the
legacy MLX path explicitly.

Add a shell alias (e.g. in `~/.zshrc`) that pins the same external venv:

```bash
alias wilted='~/Documents/Projects/wilted/scripts/wilted-runtime.sh'
```

This ensures the alias always uses the project's managed venv with all
dependencies (including playwright for browser-based article fetching), kept
outside iCloud so it never gets re-hidden. The `Makefile` and the nightly
launchd script set `UV_PROJECT_ENVIRONMENT` to the same path.

## Launch Contract

The production launch chain is:

```text
wilted alias → wilted-runtime.sh → /usr/local/bin/bws run → allowlisted environment → wilted.cli:main
```

The exact launch venv is `~/.venvs/wilted`. The speech daemon is mandatory for
speech-producing work and must be installed and started with `make install-daemon`
before playback, export, TUI use, or background jobs that synthesize or transcribe
audio. Help, version, and non-speech management commands stay daemon-independent;
speech paths probe readiness at the speech boundary and fail loudly when the daemon
is stopped or unhealthy.

Credentialed podcast feeds are stored as `bws:UPPERCASE_SNAKE_CASE` references
rather than URLs. Add the URL to Bitwarden Secrets Manager under that name, then run
Wilted through the alias above (or reinstall the nightly launchd job). The
launcher reads its dedicated `wilted-runtime` Keychain token only for the
outer BWS process, then starts Wilted with exactly the three feed values and
no BWS credentials or unrelated secrets. Its non-secret allowlist retains
terminal/locale settings plus `WILTED_DEBUG`, `WILTED_WEATHER_TEST_TRIGGER`,
`NERD_FONTS`, `WILTED_TRANSCRIBE_TIMEOUT_S`, and
`WILTED_TRANSCRIBE_MEM_LIMIT`. SQLite stores an opaque per-episode reference
instead.

If the launcher, speech backend, or launch venv changes, update this section
and the alias together. The alias remains the canonical interactive command.

### Troubleshooting

If `wilted` exits with `ModuleNotFoundError: No module named 'wilted'`, the venv's `.pth` files probably have the `UF_HIDDEN` filesystem flag set — Python 3.13's `site.py` silently skips hidden `.pth` files, so the editable install pointer to `src/` never lands on `sys.path`. This happens when the venv lives under `~/Documents/` (iCloud-synced) instead of `~/.venvs/`. The durable fix is the `UV_PROJECT_ENVIRONMENT` setup above; if you hit it on an in-iCloud venv, clear the flag:

```bash
chflags nohidden .venv/lib/python*/site-packages/*.pth
```

Confirm with `ls -lO ~/.venvs/wilted/lib/python*/site-packages/*.pth` — the flags column should be `-`, not `hidden`. The flag is set when something (iCloud Drive, a Finder copy/merge, certain backup tools) touches files under `~/Documents/`. Stray `lib 2/` or `include 2/` directories inside a venv are a related symptom; both can be removed safely.

### Development

```bash
uv sync --group dev   # install with dev/test deps
make install-hooks                 # activate pre-commit hooks (ruff + vulture + policy)
make validate                      # lint + dead-code + full test suite
```

Run `make install-hooks` once per clone — without it the `.pre-commit-config.yaml`
hooks are inert and never fire on `git commit`.

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

## Station mode

The current implementation unifies content into a local personal radio station accessible through the TUI. The station mode automates playback with intelligent interruption and recovery:

- **Morning briefing** — starts each session with a ≤5-min configurable NWS weather forecast and top-N classified items from the queue
- **Continuous playback** — plays queued articles (TTS) and prepared podcasts (audio) with ad-cuts and segment-based navigation
- **Weather bulletin interrupt** — NWS alerts interrupt playback near a transcript boundary (a ±1 s tolerance band around each segment start, so the interrupt lands within ~1 s of a real boundary — wide enough that the once-per-second offset poll reliably catches it); the *live* playback offset is what gets checkpointed, so the bulletin plays in full and then resumes the interrupted entry at the exact position with no skipped audio
- **Audio-route recovery** — device changes (speaker → headphones, AirPods connect/disconnect) are detected; playback stops with a no-output floor message, then resumes on the new device at the exact offset with no content loss
- **Automatic cleanup** — weather bulletins expire and are garbage-collected at session end; no stale bulletin files accumulate

The station is implemented as a headless substrate-neutral reducer (`src/wilted/station/`) with a TUI adapter that routes all mutations through a single `StationController` to ensure consistent state and prevent split-brain across concurrent clients.

### Launching the station

```bash
make station         # or just `wilted` — launches the TUI with the LIVE NWS weather monitor
make station-test    # launches with the weather-bulletin TEST TRIGGER armed
```

`make station` (and the plain `wilted` alias) runs the real NWS monitor: a weather bulletin only fires when there is a genuine active Severe/Tornado alert for the configured zone.

### Testing the weather bulletin on demand

The weather-bulletin interrupt is the one station feature that can't fire without a real alert, so there's a manual test hook. **It only works under `make station-test`** — a plain `wilted`/`make station` launch runs live-NWS mode and ignores the trigger file entirely:

```bash
make station-test
# in ANOTHER shell, while a transcript-backed podcast/article is playing:
touch /tmp/wilted-fire-bulletin
```

The marker is detected on the next monitor poll (at most 30 seconds), then the bulletin is synthesized and handed off. Playback waits until it enters the next safe window, which is a ±1-second band around a transcript-segment boundary. That ±1-second value is the window width, not a maximum wait: the boundary wait depends on the playing content. In the 2026-07-15 A.5.1 run, the marker was created at about 13:16:57, the bulletin was ready at 13:17:06, and playback reached a safe window at 13:17:31 — a 25-second boundary wait and about 34 seconds total. A direct warm synthesis measured 0.529 seconds against the 5-second warm-generation ceiling; polling and boundary wait are reported separately.

The trigger file is consumed automatically, so one `touch` fires at most one bulletin and does not fire again after a station relaunch. To run another test, wait at least 31 seconds after the first bulletin is handed off so one empty poll can clear its dedup state, then touch the file again; recreating it before that clear poll can be consumed as a same-severity duplicate without playing. The weather status line shows **`TEST-TRIGGER ARMED — touch /tmp/wilted-fire-bulletin`** whenever the hook is active, so you can confirm at a glance that a `touch` will actually do something. If it does *not* say that, you launched in live-NWS mode. The bulletin lifecycle (`received and PENDING`, `INTERRUPTING`) and the armed mode are logged at WARNING in `/tmp/wilted.log`; run with `--debug` for per-tick safe-point detail.

## Product direction (longer term)

The roadmap beyond station mode includes:

- always-on radio-mode playback that fills airtime from queue, feeds, and discovered content
- priority interrupt thresholds for breaking/important stories with configurable freshness windows
- time-of-day awareness — morning news, midday light, evening education/entertainment
- unified private-feed surface merging saved articles, subscribed feeds, and podcast episodes
- cross-device briefing export for sharing morning reports to another surface

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
    fetch.py             # browser fetch, subprocess-output suppression, URL helpers
    fetch_cascade.py     # unified article-text cascade: resolve_article_text(url, budget)
    queue.py             # reading list persistence (SQLite-backed)
    cache.py             # audio cache (MP3 storage, manifest)
    text.py              # text cleaning and splitting
    ingest.py            # shared article ingestion
    playlists.py         # playlist CRUD and default-playlist bootstrap
    feeds.py             # feed subscription CRUD
    discover.py          # RSS polling, dedup, article fetch
    classify.py          # LLM-based classification + benchmark
    content_state.py     # orthogonal content facts, query predicates, transitions
    pipeline_runner.py   # bounded runner (one lock, one coordinator, per-job isolation)
    pipeline_submit.py   # submit classify/prepare jobs to the processing ledger
    processing_jobs.py   # ProcessingJob admission, claim, cancellation, recovery
    legacy_cutover.py    # explicit maintenance-only status → orthogonal cutover
    background_work/     # contracts, transitions, idempotency, legacy mapping
    handlers/            # pipeline stage handlers invoked by PipelineRunner
    llm.py               # LLM backend interface (MLX, GGUF)
    preferences.py       # keyword-based relevance scoring
    log.py               # RotatingFileHandler setup
    station/             # substrate-neutral station contract layer (Mac-radio Phase 0)
        __init__.py    # export public API
        models.py      # frozen value objects (StationEntry, MediaDescriptor, etc.)
        protocols.py   # typing.Protocol seams (StationStore, PlaybackAdapter)
        reducer.py     # pure state-transition reducer apply(state, action, requester_lease)
    tui/                 # Textual TUI (decomposed package)
tests/                   # pytest suite (1,660 collected tests with overlapping lane markers)
migrations/              # numbered schema migrations
docs/adr/                # architecture decision records
    0001-mac-radio-substrate.md  # Mac-first personal-radio substrate decision (candidate a: headless core)
spikes/                  # Phase-0 feasibility prototypes (disposable, removable)
    mac-substrate-2026-07-10/       # two candidate substrates, shared reducer fixture
    migration-rehearsal-2026-07-10/ # versioned JSON store + media/<sha256> validation
    pairing-security-2026-07-10/    # threat model + Python cryptography+keyring spike
```

## Validation

Routine validation uses tiered lanes. The suite currently collects 1,748 tests
with one marker per file:

- `780` unit tests
- `812` integration tests
- `30` subprocess e2e tests
- `126` TUI tests

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
- concurrency guardrails for the optional in-process LLM coordinator lease
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
- Do not let the first `tqdm` lock initialization happen inside a Textual worker thread.

## Feed management

Subscribe to RSS/Atom feeds for automatic content discovery:

```bash
wilted feed add https://example.com/feed.xml --type article --playlist Work
wilted feed add https://example.com/pod.xml --type podcast --playlist Fun
wilted feed list
wilted feed remove 3
```

After a successful `feed add`, you'll be prompted to run `discover` and then `prepare` (defaults to Yes on enter). Use `--yes` / `-y` to skip prompts and chain both (good for shell aliases), or `--no-chain` to suppress them entirely (good for scripts and cron):

```bash
wilted feed add <url> --type podcast --playlist Work --yes        # chain everything
wilted feed add <url> --type podcast --playlist Work --no-chain   # just record the subscription
```

Run the nightly pipeline stages:

```bash
wilted discover              # poll feeds, fetch articles, dedup
wilted classify              # categorize, score, summarize (submitted to bounded pipeline runner)
wilted prepare               # transcribe/cut/TTS selected items (same runner path)
wilted benchmark classify --models "model1,model2"  # compare classification models
```

Classification, preparation, discovery, report assembly, briefing artifacts, and TUI article-cache
generation all run through the durable processing-job ledger and a bounded `PipelineRunner` (one
execution lock and one model coordinator per invocation). Expensive ML construction requires runner
authority; **INV-10** pairs runtime capability gating with an AST guard so production modules outside
the narrow handler allowlist cannot call gated factories directly.

### Background scheduler

Install launchd agents (legacy 2:00 AM email report + hourly bounded scheduler tick):

```bash
make install-launchd
```

The hourly agent runs `scripts/wilted-scheduler.sh`, which invokes one bounded tick via the same
`wilted-runtime.sh` launch chain as interactive use. One tick acquires the Python `fcntl` lock,
checks persisted due state, and drains at most one batch of due jobs — no shell `flock`, no orphan
runner process. A live foreground station defers the tick (the runner probes the station lease) so
background model/TTS work never competes with playback for the audio device.

Run a tick manually:

```bash
wilted scheduler tick
```

**Resource-aware deferral (INV-12).** Within a tick the claim seam is resource-aware: expensive
local-model work (article-cache TTS/STT, compact-briefing, speech-requiring prepare) is not claimed
during the local daytime busy window (default 08:00–20:00) when there is already enough finished audio
to play. It is a stateless *filter*, not a new state — a deferred job simply stays `queued` and is
claimed later (after the window, or once inventory runs low); there is no `deferred` state, sweep, or
promotion. Cheap/medium work always runs. Deferral never starves an interactive-priority or
aged-past-ceiling job, and a genuinely idle machine (low load, on AC, user idle) runs the work anyway.
If the availability sensor can't be read the policy fails open (runs the job). All thresholds are
settings-overridable, resolved live under the current data dir:
`scheduling_daytime_start_hour`, `scheduling_daytime_end_hour`, `scheduling_enough_inventory`,
`scheduling_max_defer_hours`, `scheduling_idle_load_per_core`, `scheduling_idle_min_seconds`,
`scheduling_interactive_priority_floor`.

Inspect what the policy would do right now (read-only — claims and writes nothing):

```bash
wilted queue status
# e.g. "3 expensive jobs held until 20:00; 1 bypassed (priority)"  — or  "no expensive jobs held"
```

Logs: `~/Library/Logs/homelab/wilted-scheduler/` (and `~/Library/Logs/homelab/wilted-nightly/`),
matching the homelab `ldstatus` convention. Each dir also holds `launchd.stdout.log` /
`launchd.stderr.log`, where launchd captures any wrapper-level fault that occurs before the wrapper's
own per-run log redirect lands (a `set -euo pipefail` abort, a TCC exit-126). Uninstall with
`make uninstall-launchd`.

**macOS Full Disk Access (required for the launchd agents).** The wrappers invoke the runtime as
`/bin/bash "$WILTED_RUNTIME"` (launchd cannot exec a script resident under `~/Documents` — TCC returns
exit 126), and the runtime runs `uv run --no-sync --frozen` against the dev-provisioned venv at
`~/.venvs/wilted` (a background tick must never re-resolve/sync deps — that stage stalls under
launchd's clean environment). Even so, the chain runs under `bws run`, which macOS treats as the TCC
*responsible process*; because the project source lives under the protected `~/Documents` tree, the
agents will **stall in a blocked `open()`** until Full Disk Access is granted to `bws` (and, if still
blocked, `uv` and the venv python) in System Settings → Privacy & Security → Full Disk Access. Until
then, keep the agents booted out (`launchctl bootout gui/$(id -u)/local.wilted-scheduler`).

### Database maintenance

Orthogonal content state (fetch, analysis, preparation, playback, retention) replaces the legacy
monolithic `Item.status` after an explicit maintenance cutover — ordinary startup does not apply it:

```bash
wilted db cutover --dry-run              # plan mapping and cohort reconciliation
wilted db cutover --backup-dir data/backups   # verified backup, then destructive cutover
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
4. Or install the launchd schedule: `make install-launchd` (2:00 AM email report + hourly scheduler tick)

## Roadmap

- Near term:
  - unified content model (articles + podcasts + playlists in one schema)
  - playlist rules (assignment, override, decay)
- Content preparation (Phase 4):
  - podcast audio download and transcription (RSS transcript ingest + speech-daemon transcription)
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
- ~~Playlists + Polish (Phase 5)~~ (done: dynamic/static playlists, CLI `wilted playlist`, `ensure_default_playlists` on startup, email morning report, nightly wrapper script, launchd integration.)
- ~~E2e test coverage + playback verification~~ (done: tiered automated suite plus manual speaker verification)
- ~~Resource-aware processing queue~~ (done: expensive local-model jobs defer out of the daytime busy window when listenable inventory is sufficient — INV-12, stateless filter; `wilted queue status` surfaces the projection.)

## Dependencies

- Python 3.12+ (via Homebrew)
- ffmpeg (required for MP3 audio caching; `brew install ffmpeg`)
- speech-stack daemon (mandatory; it owns Kokoro TTS and Parakeet inference and model residency)
- trafilatura (article text extraction)
- peewee (SQLite ORM)
- feedparser (RSS/Atom parsing)
- numpy
- textual (TUI framework)
- sounddevice (audio playback)
