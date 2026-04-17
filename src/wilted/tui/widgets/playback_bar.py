"""PlaybackBar widget — renders the state icon, progress bar, para count, and timer."""

from __future__ import annotations

from textual.widgets import Static

from wilted import ICONS

# Playback icon helpers
_ICON_PLAYING = ICONS["playing"]
_ICON_PAUSED = ICONS["paused"]

# Fractional block characters for smooth progress bar fill
_BLOCKS = " ▏▎▍▌▋▊▉█"


class PlaybackBar(Static):
    """A single-line playback status bar showing icon, progress, paragraph, and time."""

    def render_bar(
        self,
        playing: bool,
        paused: bool,
        progress: float,
        paragraph_idx: int,
        paragraphs: list[str],
        estimated_remaining_secs: float,
        time_override: str = "",
    ) -> None:
        """Update the bar with current playback state.

        Args:
            playing: Whether playback is active.
            paused: Whether playback is paused.
            progress: Progress percentage (0–100).
            paragraph_idx: Current paragraph index (0-based).
            paragraphs: Full list of paragraphs for the current article.
            estimated_remaining_secs: Seconds remaining (used when time_override is empty).
            time_override: Override string for the time field (e.g. during export).
        """
        # State icon
        if paused:
            icon = _ICON_PAUSED
        elif playing:
            icon = _ICON_PLAYING
        else:
            icon = ""

        # Progress bar — fractional block characters for smooth fill
        bar_width = 20
        frac = max(0.0, min(progress / 100, 1.0))
        total_eighths = int(frac * bar_width * 8)
        full_blocks = total_eighths // 8
        remainder = total_eighths % 8
        bar_str = "█" * full_blocks
        if remainder > 0 and full_blocks < bar_width:
            bar_str += _BLOCKS[remainder]
            bar_str += "░" * (bar_width - full_blocks - 1)
        else:
            bar_str += "░" * (bar_width - full_blocks)

        # Paragraph counter
        if paragraphs:
            total = len(paragraphs)
            current = min(paragraph_idx + 1, total)
            para_info = f"{current}/{total}"
        else:
            para_info = ""

        # Timer — use override (for export) or live countdown
        if time_override:
            time_str = time_override
        else:
            secs = max(0, int(estimated_remaining_secs))
            m, s = divmod(secs, 60)
            time_str = f"~{m}:{s:02d}" if secs > 0 or playing else ""

        parts = [p for p in [icon, bar_str, para_info, time_str] if p]
        self.update("  ".join(parts))
