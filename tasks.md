# Lilt — Tasks

## ASAP

- [ ] **Consolidate CLI audio path**: `_play_text()` in `lilt` duplicates model loading and uses `afplay` subprocess instead of `AudioEngine`. Refactor CLI to use `AudioEngine` so the xet workaround, error handling, and playback logic live in one place.
- [ ] **Add CLI test coverage**: The `lilt` CLI script (~437 lines) has zero test coverage. Add tests for argparse, `_play_text`, `cmd_add`, `cmd_play`, `cmd_next`, `cmd_direct`.
- [ ] **Replace hardcoded WPM 150 in CLI**: `_play_text()` uses `word_count / 150` in four places instead of the extracted `WPM_ESTIMATE` constant. The consistency test only checks `tui.py`.
- [ ] **Use `#!/usr/bin/env python3` shebang**: The `lilt` script hardcodes `#!/Users/dave/.venvs/mlx-audio/bin/python3`. Replace with env-based shebang or document the workaround.
- [ ] **Move `sounddevice` to core deps**: `engine.py` imports `sounddevice` unconditionally but it's listed under `[tui]` optional deps. Either make it a core dependency or lazy-import it.
- [ ] **Use XDG data directory**: `DATA_DIR` is computed relative to the editable install path. A non-editable install would create `data/` inside `site-packages`. Use `~/.local/share/lilt/` or `XDG_DATA_HOME`.

## Backlog

- [ ] End-to-end smoke test: launch fresh `lilt` process, load real model, synthesize short clip, confirm playback
- [ ] Pre-generated audio for instant playback
- [ ] Custom RSS feed subscriptions
- [ ] Apple Podcast integration (private feed)
- [ ] Unified ad-free feed (download existing podcasts, strip ads, merge into private feed)
