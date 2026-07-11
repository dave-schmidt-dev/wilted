"""Tests for ``wilted.station_runtime.briefing`` — the station briefing generator.

Covers Plan A Task 4.1:
  - stable top-N snapshot (CR-13): a briefing's item set never changes after
    generation, even if the underlying classification/ranking changes later.
  - generation-time + max-age: ``Briefing.is_stale`` /
    ``BriefingGenerator.ensure_fresh`` regenerate-if-stale, no-op if fresh.
  - the assembled script respects the configurable ``max_duration_s`` budget.
  - ``[briefing]`` wilted.toml wiring (``BriefingGenerator.from_config``).

The NWS fetch and TTS synth seams are always injected here — no live network
call and no real model load anywhere in this file. ``test_default_synth_fn_*``
is the one exception that exercises the REAL ``ModelCoordinator``, but still
with a fake ``AudioEngine`` (mirrors ``tests/test_coordinator.py``'s
``FakeAudioEngine``), so it proves the production wiring goes through the TTS
lease without ever touching mlx_audio/sounddevice.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from wilted import WPM_ESTIMATE
from wilted.db import Item
from wilted.station_runtime import briefing as briefing_mod
from wilted.station_runtime.briefing import BriefingGenerator
from wilted.station_runtime.coordinator import ModelCoordinator

pytestmark = pytest.mark.unit

_NOW = datetime(2026, 7, 10, 8, 0, 0, tzinfo=UTC)


# ---------------------------------------------------------------------------
# Fakes / builders
# ---------------------------------------------------------------------------


def _nws_payload(
    *,
    name: str = "Tonight",
    short_forecast: str = "Isolated Showers And Thunderstorms then Patchy Fog",
    temperature: int = 70,
    unit: str = "F",
) -> dict:
    """Shaped like the real payload captured in the A.0.3 spike (findings.md step 3)."""
    return {
        "properties": {
            "periods": [
                {
                    "number": 1,
                    "name": name,
                    "isDaytime": False,
                    "temperature": temperature,
                    "temperatureUnit": unit,
                    "shortForecast": short_forecast,
                },
                {
                    "number": 2,
                    "name": "Saturday",
                    "isDaytime": True,
                    "temperature": 85,
                    "temperatureUnit": "F",
                    "shortForecast": "Patchy Fog then Chance Showers And Thunderstorms",
                },
            ]
        }
    }


def _make_classified_item(
    title: str,
    *,
    relevance: float | None = 0.5,
    summary: str | None = None,
    playlist: str | None = "News",
    source_name: str | None = "test-feed",
    status: str = "classified",
) -> Item:
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    return Item.create(
        guid=f"test-{title}-{id(object())}",
        title=title,
        source_name=source_name,
        discovered_at=now,
        item_type="article",
        status=status,
        status_changed_at=now,
        playlist_assigned=playlist,
        relevance_score=relevance,
        summary=summary if summary is not None else f"Summary of {title}",
    )


class _FakeSynth:
    """Records every script handed to it; returns a cheap sentinel, no model load."""

    def __init__(self) -> None:
        self.calls: list[str] = []

    def __call__(self, text: str) -> str:
        self.calls.append(text)
        return f"AUDIO[{len(text)} chars]"


class FakeAudioEngine:
    """Mirrors ``tests/test_coordinator.py``'s ``FakeAudioEngine`` — no real model load."""

    def __init__(self) -> None:
        self.calls: list[str] = []
        self.received_text: str | None = None
        self.received_kwargs: dict = {}

    def load_model(self) -> None:
        self.calls.append("load_model")

    def generate_audio(self, text: str, **kwargs) -> list[float]:
        self.calls.append("generate_audio")
        self.received_text = text
        self.received_kwargs = kwargs
        return [0.0, 0.0]


def _generator(**overrides) -> BriefingGenerator:
    kwargs = {"fetch_fn": _nws_payload, "synth_fn": _FakeSynth()}
    kwargs.update(overrides)
    return BriefingGenerator(**kwargs)


# ---------------------------------------------------------------------------
# Basic generation
# ---------------------------------------------------------------------------


class TestGenerate:
    def test_produces_weather_and_top_n_items(self):
        _make_classified_item("Big Story", relevance=0.9)
        _make_classified_item("Medium Story", relevance=0.6)
        _make_classified_item("Small Story", relevance=0.3)

        synth = _FakeSynth()
        gen = _generator(synth_fn=synth, top_n=2, max_duration_s=300)

        result = gen.generate(now=_NOW)

        assert [item.title for item in result.items] == ["Big Story", "Medium Story"]
        assert result.weather is not None
        assert result.weather.short_forecast.startswith("Isolated Showers")
        assert result.weather.temperature == 70
        assert result.generated_at == _NOW
        assert synth.calls == [result.script]
        assert "Big Story" in result.script
        assert result.estimated_duration_s <= result.max_duration_s

    def test_excludes_non_classified_items(self):
        _make_classified_item("Classified Item", relevance=0.5)
        _make_classified_item("Draft Item", relevance=0.9, status="discovered")

        gen = _generator(top_n=5)
        result = gen.generate(now=_NOW)

        assert [item.title for item in result.items] == ["Classified Item"]

    def test_null_relevance_sorts_last(self):
        """Mirrors report.py's ``.desc(nulls="last")`` convention (report.py:52)."""
        _make_classified_item("No Score", relevance=None)
        _make_classified_item("Has Score", relevance=0.1)

        gen = _generator(top_n=5)
        result = gen.generate(now=_NOW)

        assert [item.title for item in result.items] == ["Has Score", "No Score"]

    def test_weather_fetch_failure_falls_back_without_aborting(self):
        def _raise_fetch():
            raise TimeoutError("simulated NWS timeout")

        synth = _FakeSynth()
        gen = _generator(fetch_fn=_raise_fetch, synth_fn=synth)

        result = gen.generate(now=_NOW)

        assert result.weather is None
        assert "unavailable" in result.script.lower()
        # One bad NWS call must not block the rest of the briefing (still synthesized).
        assert len(synth.calls) == 1


# ---------------------------------------------------------------------------
# CR-13: stable top-N snapshot
# ---------------------------------------------------------------------------


class TestSnapshotStability:
    def test_survives_later_classification_changes(self):
        high = _make_classified_item("High Relevance", relevance=0.9)
        _make_classified_item("Low Relevance", relevance=0.1)

        gen = _generator(top_n=2)
        result = gen.generate(now=_NOW)
        original_titles = [item.title for item in result.items]
        assert original_titles == ["High Relevance", "Low Relevance"]

        # Mutate the underlying classification/ranking AFTER generation.
        low = Item.get(Item.title == "Low Relevance")
        low.relevance_score = 0.99
        low.save()
        high.title = "Renamed After Generation"
        high.summary = "Completely different summary"
        high.save()

        # The ALREADY-generated briefing must not have moved.
        assert [item.title for item in result.items] == original_titles
        assert result.items[0].title == "High Relevance"
        assert result.items[0].summary != "Completely different summary"

    def test_new_generation_reflects_current_state(self):
        """A fresh generate() call, unlike the frozen object above, DOES see live state."""
        high = _make_classified_item("High Relevance", relevance=0.9)
        low = _make_classified_item("Low Relevance", relevance=0.1)

        gen = _generator(top_n=2)
        gen.generate(now=_NOW)  # first snapshot, discarded

        low.relevance_score = 0.99
        low.save()
        high.title = "Renamed After Generation"
        high.save()

        later = gen.generate(now=_NOW)
        assert [item.title for item in later.items] == ["Low Relevance", "Renamed After Generation"]


# ---------------------------------------------------------------------------
# generation-time + max-age / regenerate-if-stale
# ---------------------------------------------------------------------------


class TestMaxAgeRegeneration:
    def test_fresh_briefing_is_not_stale(self):
        gen = _generator(max_age_s=60)
        result = gen.generate(now=_NOW)

        assert result.is_stale(_NOW + timedelta(seconds=30)) is False

    def test_briefing_past_max_age_is_stale(self):
        gen = _generator(max_age_s=60)
        result = gen.generate(now=_NOW)

        assert result.is_stale(_NOW + timedelta(seconds=61)) is True

    def test_exactly_at_max_age_is_not_yet_stale(self):
        """Boundary: age == max_age_s is still fresh (strictly-greater-than cutoff)."""
        gen = _generator(max_age_s=60)
        result = gen.generate(now=_NOW)

        assert result.is_stale(_NOW + timedelta(seconds=60)) is False

    def test_ensure_fresh_returns_same_object_when_fresh(self):
        synth = _FakeSynth()
        gen = _generator(synth_fn=synth, max_age_s=60)
        first = gen.generate(now=_NOW)

        result = gen.ensure_fresh(first, now=_NOW + timedelta(seconds=30))

        assert result is first
        assert len(synth.calls) == 1  # not resynthesized

    def test_ensure_fresh_regenerates_when_stale(self):
        synth = _FakeSynth()
        gen = _generator(synth_fn=synth, max_age_s=60)
        first = gen.generate(now=_NOW)
        later_now = _NOW + timedelta(seconds=61)

        result = gen.ensure_fresh(first, now=later_now)

        assert result is not first
        assert result.generated_at == later_now
        assert len(synth.calls) == 2

    def test_ensure_fresh_generates_when_current_is_none(self):
        gen = _generator()

        result = gen.ensure_fresh(None, now=_NOW)

        assert result.generated_at == _NOW


# ---------------------------------------------------------------------------
# Configurable duration budget
# ---------------------------------------------------------------------------


class TestBudget:
    def test_tight_budget_truncates_items(self):
        for i in range(10):
            _make_classified_item(f"Story {i}", relevance=1.0 - i * 0.05, summary="word " * 20)

        gen = _generator(top_n=10, max_duration_s=6)  # 6s -> 15 words at WPM_ESTIMATE=150
        result = gen.generate(now=_NOW)

        assert len(result.items) < 10
        max_words = round(6 / 60 * WPM_ESTIMATE)
        assert result.word_count <= max_words
        assert result.estimated_duration_s <= result.max_duration_s

    def test_generous_budget_includes_all_requested_items(self):
        for i in range(3):
            _make_classified_item(f"Story {i}", relevance=1.0 - i * 0.1)

        gen = _generator(top_n=3, max_duration_s=300)
        result = gen.generate(now=_NOW)

        assert len(result.items) == 3

    def test_budget_never_exceeded_regardless_of_item_count(self):
        for i in range(25):
            _make_classified_item(f"Story {i}", relevance=1.0 - i * 0.01, summary="filler word " * 30)

        gen = _generator(top_n=25, max_duration_s=30)
        result = gen.generate(now=_NOW)

        max_words = round(30 / 60 * WPM_ESTIMATE)
        assert result.word_count <= max_words


# ---------------------------------------------------------------------------
# Injectable synth seam / production wiring
# ---------------------------------------------------------------------------


class TestSynthSeam:
    def test_default_synth_fn_routes_through_coordinator_run_tts(self):
        _make_classified_item("Only Item", relevance=0.9)
        engine = FakeAudioEngine()
        coordinator = ModelCoordinator()
        gen = BriefingGenerator(
            fetch_fn=_nws_payload,
            coordinator=coordinator,
            engine=engine,
            top_n=1,
        )

        result = gen.generate(now=_NOW)

        # load_model + generate_audio only happen via ModelLease.load/run inside
        # coordinator.run_tts — this is the INV-1/INV-2 lease path, not a bypass.
        assert engine.calls == ["load_model", "generate_audio"]
        assert engine.received_text == result.script
        assert coordinator.peak_concurrent_residency == 1

    def test_injected_synth_fn_bypasses_coordinator_entirely(self):
        """The seam tests rely on: injecting synth_fn must mean NO coordinator/engine touched."""
        synth = _FakeSynth()
        gen = BriefingGenerator(fetch_fn=_nws_payload, synth_fn=synth)
        # No coordinator/engine passed and none constructed — proven by the fact
        # this never imports mlx_audio/sounddevice (see stub_audio_modules
        # fixture being unused/absent here) and still returns cleanly.

        result = gen.generate(now=_NOW)

        assert synth.calls == [result.script]
        assert result.synth_result == f"AUDIO[{len(result.script)} chars]"


# ---------------------------------------------------------------------------
# wilted.toml [briefing] wiring
# ---------------------------------------------------------------------------


class TestFromConfig:
    def test_reads_briefing_table(self, monkeypatch):
        monkeypatch.setattr(
            briefing_mod,
            "load_config",
            lambda: {"briefing": {"max_duration_s": 120, "max_age_s": 900, "top_n": 2}},
        )

        gen = BriefingGenerator.from_config()

        assert gen.max_duration_s == 120
        assert gen.max_age_s == 900
        assert gen.top_n == 2

    def test_explicit_override_wins_over_toml(self, monkeypatch):
        monkeypatch.setattr(
            briefing_mod,
            "load_config",
            lambda: {"briefing": {"max_duration_s": 120}},
        )

        gen = BriefingGenerator.from_config(max_duration_s=45)

        assert gen.max_duration_s == 45

    def test_defaults_when_no_briefing_table(self, monkeypatch):
        monkeypatch.setattr(briefing_mod, "load_config", lambda: {})

        gen = BriefingGenerator.from_config()

        assert gen.max_duration_s == briefing_mod._DEFAULT_MAX_DURATION_S
        assert gen.max_age_s == briefing_mod._DEFAULT_MAX_AGE_S
        assert gen.top_n == briefing_mod._DEFAULT_TOP_N
