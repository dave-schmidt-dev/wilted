"""Allowlisted tier-3 transcription entry for pipeline handlers."""

from __future__ import annotations

from typing import TYPE_CHECKING

from wilted.transcribe import TranscriptSegment, transcribe_audio

if TYPE_CHECKING:
    from pathlib import Path


def transcribe_tier3(audio_path: Path) -> list[TranscriptSegment]:
    """Run tier-3 local transcription under runner execution capability."""
    return transcribe_audio(audio_path)
