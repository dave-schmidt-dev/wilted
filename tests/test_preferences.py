"""Tests for Phase 2 — Keyword preferences (preferences.py)."""

from __future__ import annotations

import pytest

from wilted.preferences import (
    add_keyword,
    get_keywords_for_prompt,
    list_keywords,
    remove_keyword,
)


class TestAddKeyword:
    def test_basic_add(self):
        kw = add_keyword("kubernetes")
        assert kw.keyword == "kubernetes"
        assert kw.weight == 1.0
        assert kw.created_at.endswith("Z")

    def test_add_with_weight(self):
        kw = add_keyword("security", weight=2.0)
        assert kw.weight == 2.0

    def test_duplicate_raises(self):
        add_keyword("python")
        with pytest.raises(ValueError, match="already exists"):
            add_keyword("python")

    def test_empty_keyword_raises(self):
        with pytest.raises(ValueError, match="cannot be empty"):
            add_keyword("")

    def test_whitespace_only_raises(self):
        with pytest.raises(ValueError, match="cannot be empty"):
            add_keyword("   ")

    def test_strips_whitespace(self):
        kw = add_keyword("  docker  ")
        assert kw.keyword == "docker"

    def test_zero_weight_raises(self):
        with pytest.raises(ValueError, match="positive"):
            add_keyword("test", weight=0)

    def test_negative_weight_raises(self):
        with pytest.raises(ValueError, match="positive"):
            add_keyword("test", weight=-1.0)


class TestListKeywords:
    def test_empty(self):
        assert list_keywords() == []

    def test_ordered_by_weight_desc(self):
        add_keyword("low", weight=0.5)
        add_keyword("high", weight=2.0)
        add_keyword("medium", weight=1.0)
        keywords = list_keywords()
        assert [kw.keyword for kw in keywords] == ["high", "medium", "low"]

    def test_same_weight_ordered_alphabetically(self):
        add_keyword("zebra")
        add_keyword("alpha")
        keywords = list_keywords()
        assert [kw.keyword for kw in keywords] == ["alpha", "zebra"]


class TestRemoveKeyword:
    def test_remove_existing(self):
        add_keyword("remove-me")
        removed = remove_keyword("remove-me")
        assert removed.keyword == "remove-me"
        assert list_keywords() == []

    def test_remove_nonexistent_raises(self):
        with pytest.raises(ValueError, match="not found"):
            remove_keyword("nonexistent")


class TestGetKeywordsForPrompt:
    def test_empty_returns_empty_string(self):
        assert get_keywords_for_prompt() == ""

    def test_formats_keywords(self):
        add_keyword("kubernetes", weight=1.5)
        add_keyword("security", weight=2.0)
        result = get_keywords_for_prompt()
        assert "User interest keywords" in result
        assert "kubernetes" in result
        assert "security" in result
        assert "weight: 2.0" in result
        assert "weight: 1.5" in result
