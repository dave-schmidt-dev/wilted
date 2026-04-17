"""Tests for Phase 2 — Classification stage (classify.py)."""

from __future__ import annotations

import json
from datetime import UTC, datetime

import pytest

import wilted
from wilted.classify import (
    _build_user_prompt,
    _parse_classification,
    classify_item,
    run_classify,
)
from wilted.db import Item
from wilted.preferences import add_keyword


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _make_item(text: str | None = None, **kwargs):
    """Create a fetched item, optionally with a transcript file."""
    defaults = dict(
        feed=None,
        guid="test-guid",
        title="Test Article",
        discovered_at=_now(),
        item_type="article",
        status="fetched",
        status_changed_at=_now(),
        word_count=100,
    )
    defaults.update(kwargs)
    item = Item.create(**defaults)

    if text is not None:
        path = wilted.ARTICLES_DIR / f"{item.id}_test.txt"
        path.write_text(text)
        item.transcript_file = str(path)
        item.save()

    return item


class MockLLMBackend:
    """Mock LLM backend that returns canned classification responses."""

    def __init__(self, response: str | dict | None = None):
        if response is None:
            response = {
                "playlist": "Work",
                "relevance_score": 0.85,
                "summary": "A test article about technology.",
            }
        if isinstance(response, dict):
            self._response = json.dumps(response)
        else:
            self._response = response
        self.loaded = False
        self.closed = False
        self.generate_calls = 0

    def load(self):
        self.loaded = True

    def generate(self, system_prompt: str, user_content: str) -> tuple[str, int]:
        self.generate_calls += 1
        return self._response, len(self._response) // 4

    def close(self):
        self.closed = True


# ---------------------------------------------------------------------------
# _parse_classification
# ---------------------------------------------------------------------------


class TestParseClassification:
    def test_valid_response(self):
        resp = '{"playlist": "Work", "relevance_score": 0.8, "summary": "Summary."}'
        result = _parse_classification(resp)
        assert result["playlist"] == "Work"
        assert result["relevance_score"] == 0.8
        assert result["summary"] == "Summary."

    def test_case_insensitive_playlist(self):
        resp = '{"playlist": "work", "relevance_score": 0.5, "summary": "S."}'
        result = _parse_classification(resp)
        assert result["playlist"] == "Work"

    def test_invalid_playlist_defaults_to_education(self):
        resp = '{"playlist": "News", "relevance_score": 0.5, "summary": "S."}'
        result = _parse_classification(resp)
        assert result["playlist"] == "Education"

    def test_score_clamped_to_range(self):
        resp = '{"playlist": "Fun", "relevance_score": 1.5, "summary": "S."}'
        result = _parse_classification(resp)
        assert result["relevance_score"] == 1.0

        resp2 = '{"playlist": "Fun", "relevance_score": -0.5, "summary": "S."}'
        result2 = _parse_classification(resp2)
        assert result2["relevance_score"] == 0.0

    def test_missing_score_defaults(self):
        resp = '{"playlist": "Fun", "summary": "S."}'
        result = _parse_classification(resp)
        assert result["relevance_score"] == 0.5

    def test_non_string_summary_converted(self):
        resp = '{"playlist": "Fun", "relevance_score": 0.5, "summary": 42}'
        result = _parse_classification(resp)
        assert result["summary"] == "42"

    def test_json_with_markdown_fences(self):
        resp = '```json\n{"playlist": "Education", "relevance_score": 0.7, "summary": "Test."}\n```'
        result = _parse_classification(resp)
        assert result["playlist"] == "Education"

    def test_non_dict_raises(self):
        with pytest.raises(ValueError, match="Expected JSON object"):
            _parse_classification("[1, 2, 3]")


# ---------------------------------------------------------------------------
# _build_user_prompt
# ---------------------------------------------------------------------------


class TestBuildUserPrompt:
    def test_basic_prompt(self):
        prompt = _build_user_prompt("My Title", "Article text.", "")
        assert "My Title" in prompt
        assert "Article text." in prompt

    def test_with_keywords(self):
        keywords = "User interest keywords:\n  - python (weight: 1.5)"
        prompt = _build_user_prompt("Title", "Text.", keywords)
        assert "python" in prompt
        assert "Score relevance higher" in prompt

    def test_long_text_truncated(self):
        long_text = " ".join(["word"] * 3000)
        prompt = _build_user_prompt("Title", long_text, "")
        assert "[truncated]" in prompt


# ---------------------------------------------------------------------------
# classify_item
# ---------------------------------------------------------------------------


class TestClassifyItem:
    def test_successful_classification(self):
        item = _make_item(text="This is about kubernetes deployment.")
        backend = MockLLMBackend()

        success = classify_item(backend, item, "")
        assert success is True

        refreshed = Item.get_by_id(item.id)
        assert refreshed.status == "classified"
        assert refreshed.playlist_assigned == "Work"
        assert refreshed.relevance_score == 0.85
        assert refreshed.summary == "A test article about technology."

    def test_no_text_sets_error(self):
        item = _make_item()  # No transcript file
        backend = MockLLMBackend()

        success = classify_item(backend, item, "")
        assert success is False

        refreshed = Item.get_by_id(item.id)
        assert refreshed.status == "error"
        assert "No text available" in refreshed.error_message

    def test_llm_failure_sets_error(self):
        item = _make_item(text="Some content.")

        class FailingBackend:
            def load(self):
                pass

            def generate(self, system_prompt, user_content):
                raise RuntimeError("GPU out of memory")

            def close(self):
                pass

        backend = FailingBackend()
        success = classify_item(backend, item, "")
        assert success is False

        refreshed = Item.get_by_id(item.id)
        assert refreshed.status == "error"

    def test_podcast_uses_title_metadata(self):
        """Podcast without transcript falls back to title + metadata."""
        item = _make_item(
            item_type="podcast_episode",
            guid="pod-1",
            source_name="My Podcast",
            author="Host Name",
        )
        backend = MockLLMBackend(
            {
                "playlist": "Fun",
                "relevance_score": 0.6,
                "summary": "A podcast episode.",
            }
        )

        success = classify_item(backend, item, "")
        assert success is True
        refreshed = Item.get_by_id(item.id)
        assert refreshed.playlist_assigned == "Fun"


# ---------------------------------------------------------------------------
# run_classify
# ---------------------------------------------------------------------------


class TestRunClassify:
    def test_no_fetched_items(self):
        stats = run_classify(model="test", backend_type="mlx")
        assert stats == {"classified": 0, "errors": 0, "total": 0}

    def test_classifies_fetched_items(self, monkeypatch):
        _make_item(
            text="Article about security.",
            guid="a1",
            title="Security Article",
        )
        _make_item(
            text="Article about cooking.",
            guid="a2",
            title="Cooking Article",
        )

        # Mock create_backend to return our mock
        mock_backend = MockLLMBackend()
        monkeypatch.setattr(
            "wilted.classify.create_backend",
            lambda *a, **kw: mock_backend,
        )

        stats = run_classify(model="test", backend_type="mlx")
        assert stats["classified"] == 2
        assert stats["errors"] == 0
        assert stats["total"] == 2
        assert mock_backend.loaded is True
        assert mock_backend.closed is True
        assert mock_backend.generate_calls == 2

    def test_skips_non_fetched_items(self, monkeypatch):
        _make_item(text="Fetched article.", guid="f1", status="fetched")
        _make_item(guid="r1", status="ready")  # Should be skipped

        mock_backend = MockLLMBackend()
        monkeypatch.setattr(
            "wilted.classify.create_backend",
            lambda *a, **kw: mock_backend,
        )

        stats = run_classify(model="test", backend_type="mlx")
        assert stats["total"] == 1
        assert mock_backend.generate_calls == 1

    def test_backend_closed_even_on_error(self, monkeypatch):
        _make_item(text="Content.", guid="e1")

        class ErrorBackend:
            def __init__(self):
                self.closed = False

            def load(self):
                pass

            def generate(self, s, u):
                raise RuntimeError("boom")

            def close(self):
                self.closed = True

        error_backend = ErrorBackend()
        monkeypatch.setattr(
            "wilted.classify.create_backend",
            lambda *a, **kw: error_backend,
        )

        stats = run_classify(model="test", backend_type="mlx")
        assert error_backend.closed is True
        assert stats["errors"] == 1

    def test_keywords_passed_to_prompt(self, monkeypatch):
        add_keyword("kubernetes", weight=2.0)
        _make_item(text="K8s article.", guid="k1")

        captured_prompts = []

        class CapturingBackend:
            def load(self):
                pass

            def generate(self, system_prompt, user_content):
                captured_prompts.append(user_content)
                return json.dumps(
                    {
                        "playlist": "Work",
                        "relevance_score": 0.9,
                        "summary": "K8s.",
                    }
                ), 20

            def close(self):
                pass

        monkeypatch.setattr(
            "wilted.classify.create_backend",
            lambda *a, **kw: CapturingBackend(),
        )

        run_classify(model="test", backend_type="mlx")
        assert len(captured_prompts) == 1
        assert "kubernetes" in captured_prompts[0]
