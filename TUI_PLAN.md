# Plan: wilted Textual TUI

## Context

The `wilted` CLI tool reads news articles aloud using Kokoro TTS via mlx-audio on Apple Silicon. It works well for one-off reads, but lacks interactive playback controls (pause, resume, skip) and has no way to resume interrupted articles. The user reads long-form articles from The Atlantic and The New Yorker (often 15,000+ words / 100+ minutes) and needs a proper player interface.

## Architecture

**Project home**: `~/Documents/Projects/wilted/` — all source, docs, and runtime data in one place. CLI alias `wilted` points here.

**Separate script**: `wilted-tui` — keeps the existing CLI clean and avoids importing Textual for simple `--add`/`--list` operations.

**Shared code via editable install**: Create a `wilted` Python package at `src/wilted/` with `pyproject.toml`, installed as `pip install -e` into the venv. Both scripts `import wilted.queue`, etc. No `sys.path` hacking. Linter/type-checker friendly.

**Separate state file**: Resume position stored in `data/state.json` (keyed by article ID), not in `queue.json`. Both files use atomic writes (write-to-temp + `os.replace()`).

**New dependency**: `textual>=8.0` (current is 8.x; install into existing `~/.venvs/mlx-audio/` venv).

## Layout

Single-screen, two-panel design:

```
┌─ wilted ──────────────────────────────────────────────┐
│                                                            │
│  Reading List (3)          │  Now Playing                  │
│  ─────────────────────     │  ──────────────────────────── │
│  > 1. The MAGA Intel...   │  The MAGA Intellectual Who... │
│    2. Sam Altman May...    │                               │
│    3. Why the Internet...  │  ████████░░░░░░░  seg 42      │
│                            │  ~18 min remaining            │
│                            │                               │
│                            │  "Few people have ever heard  │
│                            │   of Pappin. Until I began..."│
│                            │                               │
│                            │  Voice: af_heart  Speed: 1.0x │
├────────────────────────────┴──────────────────────────────-┤
│ [space] play/pause  [s] stop  [→] skip seg  [n] next      │
│ [v] voice  [a] add  [d] delete  [r] refresh  [q] quit     │
└────────────────────────────────────────────────────────────┘
```

## Key Bindings (v1 — FIFO only)

| Key | Action |
|-----|--------|
| `space` | Play / Pause / Resume |
| `s` | Stop playback |
| `enter` | Play selected article |
| `right` | Skip to next segment |
| `n` | Next article (stop current, advance queue) |
| `v` | Voice/speed settings (modal) |
| `a` | Add from clipboard |
| `d` | Delete selected article |
| `r` | Refresh queue (re-read from disk) |
| `q` | Quit (saves resume position) |

**Deferred to v2**: Previous segment (`left`), previous article (`p`), out-of-order playback. These require a playback history model.

## Audio Engine

### Two-thread model

1. **Main thread** — Textual event loop, UI updates
2. **TTS + playback worker** (`@work(thread=True)`) — generates and plays segments sequentially

### Playback via sounddevice.OutputStream (not sd.play)

Round 2 review confirmed `sd.play()` has no public API for tracking sample position (needed for pause/resume). Use an `OutputStream` instead, but kept simple — no callback, no ring buffer:

```python
def _play_audio(self, audio_np: np.ndarray):
    """Play numpy array with pause/resume/stop support."""
    block_size = 1024  # ~42ms at 24kHz — responsive pause
    stream = sd.OutputStream(samplerate=self.sample_rate, channels=1, dtype='float32')
    stream.start()
    try:
        offset = 0
        while offset < len(audio_np):
            if self._stop_event.is_set():
                break
            self._pause_event.wait()  # blocks while paused (zero CPU)
            end = min(offset + block_size, len(audio_np))
            stream.write(audio_np[offset:end].reshape(-1, 1))
            offset = end
        # Save exact position for resume if paused/stopped mid-segment
        self._sample_offset = offset
    finally:
        stream.stop()
        stream.close()
```

Pause latency: ~42ms max. No underrun on resume (pause_event.wait() blocks the write loop, stream stays open and outputs silence via its internal buffer).

### Segment tracking

Both reviews flagged the chunk/segment confusion. The model internally splits text at ~510 phonemes regardless of input chunking. The correct approach:

- **Normalize cached text** on first playback: split on `\n` (not `\n\n` — cached files use single newlines from trafilatura). Store as a list of paragraphs.
- **Pass one paragraph at a time** to `model.generate()` — each call yields 1+ segments.
- **Track progress** by `(paragraph_idx, segment_idx_within_paragraph)`.
- **`split_into_chunks`** is kept in the shared library for CLI backward compatibility but NOT used by the TUI. The TUI uses paragraph-based generation.

### Skip segment latency

With a single worker, skipping means ~1s of silence while the next segment generates. Mitigate with a visible "Generating..." status in the now-playing panel. This is acceptable for v1 — pre-buffering (look-ahead) can be added in v2 if the latency bothers the user.

### Model loading

Lazy load on first play, not on TUI launch. Show "Loading model..." in the now-playing panel. Subsequent plays reuse the loaded model.

### Voice/speed changes

- Stored as simple attributes on the AudioEngine
- The worker reads them at the start of each `model.generate()` call (per-call params, no model reload)
- Time remaining estimate adjusts for speed: `remaining_words / (150 * speed) * 60`

## Resume Support

`data/state.json`:

```json
{
  "3": {
    "paragraph_idx": 12,
    "segment_in_paragraph": 2,
    "updated": "2026-04-06T14:30:00"
  }
}
```

- Keyed by article `id` (string)
- Saved via atomic write (temp file + `os.replace()`) on: pause, stop, quit, and every ~30 seconds
- On resume: skip to saved paragraph, regenerate from that point
- Cleared when article completes or is deleted

## Voice Settings

Modal overlay triggered by `v` key:
- Voice list from a `VOICES` dict in the shared library (single source of truth for both CLI and TUI)
- Speed slider (0.5x to 2.0x, 0.1 step)
- Changes take effect on the next segment

## File Structure

```
~/Documents/Projects/wilted/
    wilted                             # existing CLI (refactored to import from package)
    wilted-tui                         # TUI entry point (NEW)
    pyproject.toml                   # package metadata (NEW)
    README.md                        # project docs
    TUI_PLAN.md                      # this plan
    LICENSE
    src/wilted/                        # shared package (NEW)
        __init__.py                  # DATA_DIR, QUEUE_FILE, ARTICLES_DIR, STATE_FILE, VOICES
        queue.py                     # load_queue, save_queue (atomic), add, remove, clear
        state.py                     # load_state, save_state (atomic), clear_state
        text.py                      # clean_text, split_into_chunks, split_paragraphs
        fetch.py                     # resolve_apple_news_url, get_text_from_url, clipboard
    data/                            # runtime data (.gitignored)
        queue.json                   # article queue (unchanged schema)
        state.json                   # resume positions (NEW)
        articles/                    # cached text (unchanged)
```

## Implementation Phases

### Phase 1: Shared library + CLI refactor
1. Create `src/wilted/` package with `pyproject.toml`
2. Extract shared functions into package modules (queue, text, fetch, state)
3. Add atomic write to `save_queue()` and new `save_state()`
4. Tests for shared library:
   - `queue.py`: load/save round-trip, add/remove/clear, atomic write (crash-safe), next-ID generation, missing file handling
   - `text.py`: clean_text strips Apple News artifacts (footer, copyright, "Follow" lines), split_into_chunks respects max_chars and sentence boundaries, split_paragraphs normalizes `\n` correctly
   - `fetch.py`: Apple News URL resolution (mock HTTP), title extraction from HTML, clipboard fallback
   - `state.py`: load/save round-trip, atomic write, clear on completion, missing file handling
5. Refactor existing CLI to import from the package
6. **Verify**: `wilted --list`, `wilted --add URL`, `wilted --clean`, `wilted --play` all work identically
7. `pip install textual sounddevice` into the venv

### Phase 2: TUI core + playback
8. Create `wilted-tui` with Textual app: Header, Footer, two-panel layout, DataTable for queue
9. AudioEngine class: model loading, OutputStream-based playback, pause/resume/stop
10. Tests for AudioEngine:
    - Pause/resume/stop state machine (mock sounddevice OutputStream, verify event logic)
    - Block-write loop respects stop_event and pause_event
    - Sample offset saved correctly on pause/stop mid-segment
11. TTS worker: paragraph-based generation, segment tracking, progress updates via `call_from_thread`
12. Tests for segment tracking:
    - Paragraph index advances correctly through article
    - Resume from saved `(paragraph_idx, segment_in_paragraph)` skips completed content
    - Completion clears state for that article
13. Key bindings: space (play/pause), s (stop), right (skip segment), n (next article), enter (play selected)
14. TUI app tests (Textual pilot):
    - App launches and displays queue from queue.json
    - Key bindings dispatch correct actions (space toggles play/pause, q quits, d deletes selected)
    - Empty queue shows appropriate message
    - Add from clipboard updates the queue list
15. Resume state: state.json persistence, resume on replay
16. Voice settings modal + speed control

### Phase 3: Polish + docs
17. Edge cases: empty queue, missing files, model load failure, audio device errors (PortAudioError catch)
18. Clean shutdown: stop audio, save state on quit
19. Tests for edge cases:
    - Missing cached article file skips gracefully
    - Corrupt queue.json / state.json handled without crash
    - Concurrent queue writes (CLI add while TUI plays) don't corrupt data
20. Update `README.md`, `HISTORY.md`, `~/Documents/Projects/LLM/README.md`, `~/Documents/Projects/LLM/HISTORY.md`

## Future Roadmap (v2+)

- **Previous segment / article navigation** — requires playback history model
- **Pre-buffered look-ahead** — generate next segment while current plays for gapless skip
- **Pre-generate audio on add** — background TTS generation at `--add` time so playback is instant with zero latency. Hybrid: fall back to streaming if audio isn't ready yet. Storage: ~1.5MB/min WAV at 24kHz mono (~150MB for a 100-min article). Generation: ~11 min for 100-min article at 0.11 RTF on M5 Max
- **Custom RSS feeds** — subscribe to publication feeds (Atlantic, New Yorker, Reason, etc.), auto-fetch new articles into queue on a schedule
- **Apple Podcast integration** — generate podcast-style audio files from reading list, publish as a private RSS feed compatible with Apple Podcasts for listening on any device
- **Unified ad-free feed** — if private feed works, extend it: download existing podcast subscriptions, strip ads (silence detection + sponsor segment databases like SponsorBlock), and merge everything into the single private feed for a clean, ad-free listening experience
- **macOS .app bundle** — Wilted.app in ~/Applications for Finder, Dock, Spotlight, and Launchpad access. Thin wrapper that opens iTerm with wilted-tui. Custom .icns icon for native look.
- **Expanded test coverage** — property-based tests for text splitting, stress tests for concurrent queue access

## Files to Create/Modify

| File | Action |
|------|--------|
| `pyproject.toml` | **Create** — package metadata, test dependencies |
| `src/wilted/*.py` | **Create** — shared modules (5 files) |
| `tests/` | **Create** — test suite (Phase 1: library, Phase 2: engine + TUI, Phase 3: edge cases) |
| `wilted` | **Modify** — import from shared package |
| `wilted-tui` | **Create** — TUI app |
| `README.md` | **Update** — add TUI docs |
| `HISTORY.md` | **Update** — log changes |
| `~/Documents/Projects/LLM/README.md` | **Update** — update wilted entry |
| `~/Documents/Projects/LLM/HISTORY.md` | **Update** — log changes |

## Verification

1. **CLI regression**: all existing commands work after refactor to shared library
2. **TUI launch**: `wilted-tui` displays queue from `queue.json`
3. **Playback**: Select article, space to play, audio starts within 2-3s (model load) or <1s (model cached)
4. **Pause/resume**: Space pauses within ~50ms, resumes from exact position
5. **Skip**: Right arrow skips to next segment, "Generating..." shown during ~1s gap
6. **Resume persistence**: Quit mid-playback → relaunch → article resumes near saved position
7. **Voice change**: Press v, change voice/speed, next segment uses new settings, time estimate adjusts
8. **Concurrent access**: `wilted --add URL` in another terminal while TUI plays doesn't corrupt queue or state
9. **Clean shutdown**: Ctrl+C or q saves state and exits without orphaned audio threads

## Review Decision Log

### Contrarian Round 1

| Finding | Decision | Rationale |
|---------|----------|-----------|
| Chunk/segment confusion | **Accept** | Track model segments, not artificial chunks |
| Double-splitting redundant | **Accept** | Pass paragraphs, let model split internally |
| OutputStream pause glitch | **Accept** | Use block-write loop with pause event |
| Textual version unspecified | **Accept** | Pin to >=8.0 |
| 3 threads unnecessary | **Accept** | Simplify to 2 threads |
| queue.json no locking | **Accept** | Separate state.json + atomic writes |
| Clipboard fetch could block audio | **Accept** | Isolated worker |
| Voice changes delayed by buffer | **Accept** | No look-ahead buffer in v1 |
| No audio device handling | **Accept** | Add PortAudioError catch |
| mpv IPC alternative | **Reject** | Adds external dependency; user wants local TTS streaming |
| afplay SIGSTOP hack | **Reject** | sounddevice already installed, cleaner API |
| Resume breaks on text changes | **Accept risk** | Unlikely for cached files; note in docs |
| Time estimate inaccurate from chunks | **Accept** | Use word count / (150 * speed) |
| 6 phases over-scoped | **Accept** | Reduced to 3 phases |
| Hardcoded constants unjustified | **Accept** | Reviewed: block_size=1024, no pre-buffer |

### Codex Review (GPT-5.4)

| Finding | Decision | Rationale |
|---------|----------|-----------|
| queue.json shared without locking | **Accept** | Separate state.json + atomic writes |
| Chunk/segment mismatch | **Accept** | Same fix as contrarian — segment-based tracking |
| Queue/player semantics undefined for non-FIFO | **Accept** | FIFO only for v1 |
| Look-ahead conflicts with controls | **Accept** | No look-ahead in v1 |
| Voice list drift (hardcoded) | **Accept** | Single VOICES dict in shared package |
| Inline function copy risky | **Accept** | Shared package via editable install |
| Manual-only verification | **Noted** | Tests deferred to roadmap; manual verification defined |
| Clipboard add behavior underspecified | **Accept** | Match existing CLI behavior |

### Contrarian Round 2

| Finding | Decision | Rationale |
|---------|----------|-----------|
| sd.play() has no public pause API | **Accept** | Switched to OutputStream block-write loop |
| Cached text \n vs \n\n inconsistent | **Accept** | Normalize: split on \n, paragraph-based |
| Textual version pin wrong (8.x not 1.x) | **Accept** | Fixed to >=8.0 |
| sys.path hacking for shared lib | **Accept** | Use pip install -e with pyproject.toml |
| state.json needs atomic writes | **Accept** | temp file + os.replace() |
| Skip has ~1s silence | **Accept** | Show "Generating..." indicator; pre-buffer in v2 |
| Voice sync unspecified | **Accept** | Simple attributes, read at generate() call boundary |
| 150 WPM ignores speed param | **Accept** | Adjust: words / (150 * speed) |
| Backup before refactoring | **Accept** | Copy to wilted.bak first |
| Model loading timing unspecified | **Accept** | Lazy load on first play |
| Scope still large / simpler approach | **Reject** | User explicitly requested Textual TUI |
| split_into_chunks fate unclear | **Accept** | Kept in shared lib for CLI; TUI uses split_paragraphs |
