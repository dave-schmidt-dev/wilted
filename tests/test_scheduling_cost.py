"""Exhaustive truth-table tests for pure job cost estimation."""

from __future__ import annotations

import pytest

from wilted.background_work.contracts import JobKind
from wilted.scheduling_cost import JobCostClass, estimate_cost_class

# (kind, item_type, checkpoint_json) -> expected JobCostClass.
# Covers every JobKind member plus every item_type/skip_tts branch that
# job_requires_speech distinguishes for PREPARE.
_TRUTH_TABLE = [
    # Always-cheap kinds: item_type/checkpoint_json are irrelevant.
    (JobKind.DISCOVER, None, None, JobCostClass.CHEAP),
    (JobKind.DISCOVER, "article", None, JobCostClass.CHEAP),
    (JobKind.DISCOVER, "podcast_episode", '{"skip_tts": true}', JobCostClass.CHEAP),
    (JobKind.REPORT_ASSEMBLY, None, None, JobCostClass.CHEAP),
    (JobKind.REPORT_ASSEMBLY, "article", None, JobCostClass.CHEAP),
    (JobKind.REPORT_ASSEMBLY, "podcast_episode", '{"skip_tts": true}', JobCostClass.CHEAP),
    # Always-medium kind (local LLM, short).
    (JobKind.CLASSIFY, None, None, JobCostClass.MEDIUM),
    (JobKind.CLASSIFY, "article", None, JobCostClass.MEDIUM),
    (JobKind.CLASSIFY, "podcast_episode", '{"skip_tts": true}', JobCostClass.MEDIUM),
    # Always-expensive kinds: always speech-capable per job_requires_speech.
    (JobKind.ARTICLE_CACHE, None, None, JobCostClass.EXPENSIVE),
    (JobKind.ARTICLE_CACHE, "article", '{"skip_tts": true}', JobCostClass.EXPENSIVE),
    (JobKind.COMPACT_BRIEFING, None, None, JobCostClass.EXPENSIVE),
    (JobKind.COMPACT_BRIEFING, "article", '{"skip_tts": true}', JobCostClass.EXPENSIVE),
    # PREPARE: cost mirrors job_requires_speech's item_type/skip_tts branches.
    (JobKind.PREPARE, "podcast_episode", None, JobCostClass.EXPENSIVE),
    (JobKind.PREPARE, "podcast_episode", '{"skip_tts": true}', JobCostClass.EXPENSIVE),
    (JobKind.PREPARE, "article", '{"skip_tts": true}', JobCostClass.CHEAP),
    (JobKind.PREPARE, "article", '{"skip_tts": false}', JobCostClass.EXPENSIVE),
    (JobKind.PREPARE, "article", None, JobCostClass.EXPENSIVE),
    (JobKind.PREPARE, "article", "not-json", JobCostClass.EXPENSIVE),
    (JobKind.PREPARE, None, None, JobCostClass.EXPENSIVE),
]


@pytest.mark.parametrize(("kind", "item_type", "checkpoint_json", "expected"), _TRUTH_TABLE)
def test_estimate_cost_class_truth_table(kind, item_type, checkpoint_json, expected):
    assert estimate_cost_class(kind, item_type=item_type, checkpoint_json=checkpoint_json) == expected


def test_every_job_kind_member_is_mapped():
    """Guard against a new JobKind member silently falling through to PREPARE handling."""
    covered_kinds = {row[0] for row in _TRUTH_TABLE}
    assert covered_kinds == set(JobKind)


def test_accepts_string_kind():
    assert estimate_cost_class("discover", item_type=None, checkpoint_json=None) is JobCostClass.CHEAP
    assert (
        estimate_cost_class(
            "prepare",
            item_type="article",
            checkpoint_json='{"skip_tts": true}',
        )
        is JobCostClass.CHEAP
    )


def test_result_is_job_cost_class_enum():
    result = estimate_cost_class(JobKind.CLASSIFY, item_type=None, checkpoint_json=None)
    assert isinstance(result, JobCostClass)
