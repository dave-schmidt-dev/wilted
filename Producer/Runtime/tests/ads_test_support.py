"""Shared test helpers and support classes for ad detection tests."""

from __future__ import annotations

import json
from dataclasses import dataclass
from unittest.mock import MagicMock


@dataclass
class TranscriptSegment:
    start_s: float
    end_s: float
    text: str
    tokens: tuple[object, ...] | None = None


@dataclass
class _AlignedToken:
    text: str
    start_s: float
    end_s: float


def _make_segments(intervals: list[tuple[float, float, str]]) -> list[TranscriptSegment]:
    """Create TranscriptSegment list from (start, end, text) tuples."""
    return [TranscriptSegment(start_s=s, end_s=e, text=t) for s, e, t in intervals]


def _mock_backend(responses: list[str]) -> MagicMock:
    """Create a mock LLM backend that returns the given responses in order."""
    backend = MagicMock()
    backend.generate = MagicMock(side_effect=[(r, 100) for r in responses])
    return backend


class AdDetectionTestSupport:
    @staticmethod
    def _classifications(ids: list[int], ad_ids: set[int] = frozenset()) -> str:
        return json.dumps({"ads": [[segment_id, "sponsor_read"] for segment_id in ids if segment_id in ad_ids]})

    @staticmethod
    def _content_backend() -> MagicMock:
        backend = MagicMock()

        def generate(_system_prompt, transcript_text):
            return json.dumps({"ads": []}), 100

        backend.generate = MagicMock(side_effect=generate)
        return backend
