"""Allowlisted classification benchmark entry."""

from __future__ import annotations

import logging
import time
from typing import TYPE_CHECKING

import wilted
from wilted.classify import (
    _BENCHMARK_ITEMS,
    _SYSTEM_PROMPT,
    _build_user_prompt,
    _ensure_db,
    _parse_classification,
    get_keywords_for_prompt,
)
from wilted.execution_capability import create_model_coordinator, execution_capability_scope
from wilted.handlers._ml import build_llm_backend

if TYPE_CHECKING:
    from wilted.llm import LLMBackend

logger = logging.getLogger(__name__)


def run_benchmark(
    *,
    models: list[str],
    backend_type: str = "gguf",
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

    with execution_capability_scope(owner_id="benchmark", data_dir=wilted.DATA_DIR):
        coordinator = create_model_coordinator()
        for model_name in models:
            backend = build_llm_backend(backend_type, model=model_name)

            correct = 0
            total_time = 0.0
            total_tokens = 0
            errors = 0

            def _benchmark_loaded(loaded_backend: LLMBackend) -> None:
                """Benchmark one model while the coordinator holds the LLM lease."""
                nonlocal correct, total_time, total_tokens, errors
                for bench_item in _BENCHMARK_ITEMS:
                    user_prompt = _build_user_prompt(
                        bench_item["title"],
                        bench_item["text"],
                        keywords_section,
                    )

                    start = time.monotonic()
                    try:
                        response, tokens = loaded_backend.generate(_SYSTEM_PROMPT, user_prompt)
                        elapsed = time.monotonic() - start

                        result = _parse_classification(response)
                        if result["playlist"] == bench_item["expected_playlist"]:
                            correct += 1

                        total_time += elapsed
                        total_tokens += tokens
                    except Exception as exc:
                        logger.warning("Benchmark error for '%s': %s", bench_item["title"], exc)
                        errors += 1
                        total_time += time.monotonic() - start

            try:
                coordinator.run_llm(backend, _benchmark_loaded)
            except Exception as exc:
                print(f"{model_name:<50} {'LOAD FAIL':>8} {str(exc)[:20]:>10}")
                continue

            evaluated = len(_BENCHMARK_ITEMS) - errors
            accuracy = correct / evaluated if evaluated > 0 else 0
            avg_time = total_time / len(_BENCHMARK_ITEMS)
            avg_tokens = total_tokens // max(1, evaluated)

            print(f"{model_name:<50} {accuracy:>7.0%} {avg_time:>9.1f}s {avg_tokens:>10d}")

    print()
