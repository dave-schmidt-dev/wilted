"""Classification stage — categorize, score, and summarize fetched items.

Stage 2 of the nightly pipeline. LLM-bound: loads model once, processes all
fetched items, then unloads.

For each fetched item:
  - Assigns a playlist category (Work, Fun, Education)
  - Scores relevance (0.0-1.0) based on user keywords
  - Generates a 2-3 sentence summary

Usage:
    from wilted.classify import run_classify
    stats = run_classify()  # {'classified': 5, 'errors': 1}
"""

from __future__ import annotations

import logging
import time

from wilted.db import Item
from wilted.db import ensure_db as _ensure_db
from wilted.db import now_utc as _now_utc
from wilted.llm import LLMBackend, create_backend, parse_json_response
from wilted.preferences import get_keywords_for_prompt

logger = logging.getLogger(__name__)


# Default classification model
_DEFAULT_MODEL = "mlx-community/gemma-4-e4b-it-4bit"
_DEFAULT_BACKEND = "mlx"

# Valid playlist categories
_VALID_PLAYLISTS = {"Work", "Fun", "Education"}

_SYSTEM_PROMPT = """\
You are a content classifier for a personal audio reading system.
For each piece of content, you must output a JSON object with exactly these fields:
- "playlist": one of "Work", "Fun", or "Education"
- "relevance_score": a float between 0.0 and 1.0 indicating how relevant this content is to the user
- "summary": a 2-3 sentence summary of the content

Rules:
- "Work": professional, technical, industry, business, productivity content
- "Fun": entertainment, humor, pop culture, sports, hobbies, lifestyle
- "Education": learning, science, history, tutorials, how-to guides, research

Output ONLY the JSON object. No markdown, no explanation, no extra text.

Example output:
{"playlist": "Work", "relevance_score": 0.85, "summary": "This article discusses new containerization \
patterns for microservices. It covers practical deployment strategies and compares Kubernetes operators \
with traditional deployment tools."}
"""


def _build_user_prompt(title: str, text: str, keywords_section: str) -> str:
    """Build the user prompt for classification."""
    # Truncate text to ~2000 words to stay within context limits
    words = text.split()
    if len(words) > 2000:
        text = " ".join(words[:2000]) + "\n\n[truncated]"

    parts = [f"Title: {title}\n\nContent:\n{text}"]

    if keywords_section:
        parts.append(f"\n\n{keywords_section}")
        parts.append("\nScore relevance higher for content matching these keywords.")

    return "\n".join(parts)


def _parse_classification(response: str) -> dict:
    """Parse and validate classification JSON from LLM response.

    Returns:
        Dict with 'playlist', 'relevance_score', 'summary'.

    Raises:
        ValueError: If response cannot be parsed or is invalid.
    """
    result = parse_json_response(response)

    if not isinstance(result, dict):
        raise ValueError(f"Expected JSON object, got {type(result).__name__}")

    playlist = result.get("playlist", "")
    if playlist not in _VALID_PLAYLISTS:
        # Try case-insensitive match
        for valid in _VALID_PLAYLISTS:
            if playlist.lower() == valid.lower():
                playlist = valid
                break
        else:
            logger.warning("Invalid playlist '%s', defaulting to 'Education'", playlist)
            playlist = "Education"

    relevance = result.get("relevance_score", 0.5)
    try:
        relevance = float(relevance)
        relevance = max(0.0, min(1.0, relevance))
    except (TypeError, ValueError):
        relevance = 0.5

    summary = result.get("summary", "")
    if not isinstance(summary, str):
        summary = str(summary)

    return {
        "playlist": playlist,
        "relevance_score": relevance,
        "summary": summary,
    }


def _get_item_text(item: Item) -> str | None:
    """Read the transcript text for an item."""
    if item.transcript_file:
        from pathlib import Path

        path = Path(item.transcript_file)
        if path.exists():
            return path.read_text(encoding="utf-8")

    # For podcasts without transcripts, use title + metadata
    if item.item_type == "podcast_episode":
        parts = [item.title]
        if item.source_name:
            parts.append(f"Source: {item.source_name}")
        if item.author:
            parts.append(f"Author: {item.author}")
        return "\n".join(parts)

    return None


def classify_item(backend: LLMBackend, item: Item, keywords_section: str) -> bool:
    """Classify a single item using the loaded LLM.

    Updates the item in-place and saves to the database.

    Returns:
        True if classification succeeded, False otherwise.
    """
    text = _get_item_text(item)
    if not text:
        logger.warning("No text available for item #%d: %s", item.id, item.title)
        item.status = "error"
        item.error_message = "No text available for classification"
        item.status_changed_at = _now_utc()
        item.save()
        return False

    user_prompt = _build_user_prompt(item.title, text, keywords_section)

    try:
        response, tokens = backend.generate(_SYSTEM_PROMPT, user_prompt)
        result = _parse_classification(response)
    except Exception as e:
        logger.error("Classification failed for item #%d: %s", item.id, e)
        item.status = "error"
        item.error_message = f"Classification error: {e}"
        item.status_changed_at = _now_utc()
        item.save()
        return False

    # Apply classification results — respect any existing playlist override
    item.playlist_assigned = result["playlist"]
    item.relevance_score = result["relevance_score"]
    item.summary = result["summary"]
    item.status = "classified"
    item.status_changed_at = _now_utc()
    item.save()

    logger.info(
        "Classified #%d: %s -> %s (%.2f)",
        item.id,
        item.title[:50],
        result["playlist"],
        result["relevance_score"],
    )
    return True


def run_classify(
    *,
    model: str | None = None,
    backend_type: str | None = None,
) -> dict:
    """Run classification on all fetched items.

    Args:
        model: Model identifier (defaults to config or _DEFAULT_MODEL).
        backend_type: Backend type (defaults to config or _DEFAULT_BACKEND).

    Returns:
        Dict with stats: {'classified': int, 'errors': int, 'total': int}
    """
    _ensure_db()

    items = list(Item.select().where(Item.status == "fetched"))
    if not items:
        logger.info("No fetched items to classify")
        return {"classified": 0, "errors": 0, "total": 0}

    # Load config defaults
    model = model or _DEFAULT_MODEL
    backend_type = backend_type or _DEFAULT_BACKEND

    # Get user keywords for relevance scoring
    keywords_section = get_keywords_for_prompt()

    logger.info("Classifying %d items with %s (%s)", len(items), model, backend_type)

    backend = create_backend(backend_type, model=model)
    backend.load()

    classified = 0
    errors = 0

    try:
        for item in items:
            success = classify_item(backend, item, keywords_section)
            if success:
                classified += 1
            else:
                errors += 1
    finally:
        backend.close()

    result = {"classified": classified, "errors": errors, "total": len(items)}
    logger.info("Classification complete: %s", result)
    return result


# ---------------------------------------------------------------------------
# Benchmarking
# ---------------------------------------------------------------------------

# Labeled test set for benchmarking classification accuracy
_BENCHMARK_ITEMS = [
    {
        "title": "Kubernetes 1.30 Release Notes",
        "text": (
            "Kubernetes 1.30 introduces sidecar containers as a stable feature, "
            "improving pod lifecycle management. The release also includes "
            "enhancements to node resource management and security policies."
        ),
        "expected_playlist": "Work",
    },
    {
        "title": "The Science of Sourdough Bread",
        "text": (
            "Researchers have identified the specific strains of lactobacillus "
            "that give sourdough its distinctive flavor. The fermentation process "
            "involves complex biochemistry practiced for thousands of years."
        ),
        "expected_playlist": "Education",
    },
    {
        "title": "Top 10 Movies of 2026 So Far",
        "text": (
            "From blockbuster sequels to indie darlings, this year has been "
            "exceptional for cinema. Our critics rank the best films released "
            "in the first half of 2026."
        ),
        "expected_playlist": "Fun",
    },
    {
        "title": "Understanding Zero Trust Architecture",
        "text": (
            "Zero trust security models assume no implicit trust. Every access "
            "request must be verified regardless of network location. This guide "
            "covers implementation strategies for enterprise environments."
        ),
        "expected_playlist": "Work",
    },
    {
        "title": "How Photosynthesis Actually Works",
        "text": (
            "The process of photosynthesis is far more complex than most textbooks "
            "suggest. Light-dependent reactions in the thylakoid membrane involve "
            "quantum coherence effects that scientists are still studying."
        ),
        "expected_playlist": "Education",
    },
    {
        "title": "Premier League Weekend Recap",
        "text": (
            "Arsenal secured a dramatic late win while Manchester City stumbled "
            "at home. Liverpool's title hopes received a boost with a convincing "
            "derby victory."
        ),
        "expected_playlist": "Fun",
    },
    {
        "title": "Building Production-Ready ML Pipelines",
        "text": (
            "Moving machine learning models from notebooks to production requires "
            "careful consideration of data versioning, model monitoring, and CI/CD "
            "integration. This covers best practices using MLflow and Kubeflow."
        ),
        "expected_playlist": "Work",
    },
    {
        "title": "The History of the Silk Road",
        "text": (
            "Ancient trade routes connecting East and West facilitated not just "
            "commerce but the exchange of ideas, religions, and technologies. "
            "The Silk Road shaped civilizations for over 1,500 years."
        ),
        "expected_playlist": "Education",
    },
    {
        "title": "New Album Reviews: What to Listen To This Week",
        "text": (
            "This week brings fresh releases from several emerging artists. "
            "Our music critics highlight the standout albums across genres "
            "from indie rock to electronic."
        ),
        "expected_playlist": "Fun",
    },
    {
        "title": "Terraform Best Practices for Multi-Cloud",
        "text": (
            "Managing infrastructure across AWS, GCP, and Azure requires careful "
            "module design and state management. This guide covers workspace "
            "strategies, remote state backends, and drift detection."
        ),
        "expected_playlist": "Work",
    },
]


def run_benchmark(
    *,
    models: list[str],
    backend_type: str = "mlx",
) -> None:
    """Run classification benchmark across multiple models.

    Prints a comparison table of accuracy, latency, and token counts.

    Args:
        models: List of model identifiers to benchmark.
        backend_type: Backend type to use for all models.
    """
    _ensure_db()

    keywords_section = get_keywords_for_prompt()

    print(f"\nBenchmarking {len(models)} model(s) on {len(_BENCHMARK_ITEMS)} items\n")
    print(f"{'Model':<50} {'Accuracy':>8} {'Avg Time':>10} {'Avg Tokens':>10}")
    print("-" * 82)

    for model_name in models:
        backend = create_backend(backend_type, model=model_name)

        try:
            backend.load()
        except Exception as e:
            print(f"{model_name:<50} {'LOAD FAIL':>8} {str(e)[:20]:>10}")
            continue

        correct = 0
        total_time = 0.0
        total_tokens = 0
        errors = 0

        try:
            for bench_item in _BENCHMARK_ITEMS:
                user_prompt = _build_user_prompt(
                    bench_item["title"],
                    bench_item["text"],
                    keywords_section,
                )

                start = time.monotonic()
                try:
                    response, tokens = backend.generate(_SYSTEM_PROMPT, user_prompt)
                    elapsed = time.monotonic() - start

                    result = _parse_classification(response)
                    if result["playlist"] == bench_item["expected_playlist"]:
                        correct += 1

                    total_time += elapsed
                    total_tokens += tokens
                except Exception as e:
                    logger.warning("Benchmark error for '%s': %s", bench_item["title"], e)
                    errors += 1
                    total_time += time.monotonic() - start
        finally:
            backend.close()

        evaluated = len(_BENCHMARK_ITEMS) - errors
        accuracy = correct / evaluated if evaluated > 0 else 0
        avg_time = total_time / len(_BENCHMARK_ITEMS)
        avg_tokens = total_tokens // max(1, evaluated)

        print(f"{model_name:<50} {accuracy:>7.0%} {avg_time:>9.1f}s {avg_tokens:>10d}")

    print()
