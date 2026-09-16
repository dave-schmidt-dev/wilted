"""LLM backend interface — protocol and implementations for local model inference.

Follows scarecrow's architecture: load once, generate many, close once.
Only one model loaded at a time; explicit unloading reclaims Metal GPU memory.

Usage:
    from wilted.llm import DEFAULT_GGUF_MODEL, create_backend

    # GGUF via llama.cpp is the default. `create_backend` accepts a local .gguf
    # path or an "hf:<repo_id>/<filename>" spec (resolved to a cached path via
    # huggingface_hub). `DEFAULT_GGUF_MODEL` is the repaired local Gemma-4 E4B
    # GGUF. The July-2026 upstream QAT snapshot has a broken tokenizer, so a
    # missing repaired file fails with setup instructions instead of downloading
    # the known-broken snapshot.
    backend = create_backend("gguf", model=DEFAULT_GGUF_MODEL)
    backend.load()
    response, tokens = backend.generate("You are a classifier.", "Classify this text.")
    backend.close()
"""

from __future__ import annotations

import gc
import json
import logging
import os
import sys
import time
from pathlib import Path
from typing import Any, Protocol, runtime_checkable

logger = logging.getLogger(__name__)

# Canonical default GGUF classification model. Google's July-2026 Gemma-4 QAT
# snapshots ship a broken tokenizer (duplicate tokens trip llama.cpp's vocabulary
# assertion), so the default is only the repaired copy in the machine-wide model
# store (~/models/gemma-4-repaired, overridable via LOCAL_MODELS_DIR). Never
# silently download the known-broken upstream file on a fresh checkout.
_MODELS_DIR = (
    Path(os.path.expanduser(os.environ.get("LOCAL_MODELS_DIR") or str(Path.home() / "models"))) / "gemma-4-repaired"
)
DEFAULT_GGUF_MODEL = str(_MODELS_DIR / "gemma-4-E4B_q4_0-it-2026-07-15-repaired.gguf")


@runtime_checkable
class LLMBackend(Protocol):
    """Protocol for local LLM inference backends.

    Each backend manages a single model. The lifecycle is:
    1. load() — load model into memory (GPU/CPU)
    2. generate() — run inference (may be called many times)
    3. close() — unload model and reclaim memory
    """

    def load(self) -> None: ...

    def generate(
        self, system_prompt: str, user_content: str, *, response_format: dict[str, Any] | None = None
    ) -> tuple[str, int]: ...

    def close(self) -> None: ...


class MlxBackend:
    """MLX-based text LLM backend using mlx-lm.

    Loads a Hugging Face model via mlx_lm and manages Metal GPU memory.
    """

    def __init__(self, model: str, max_tokens: int = 2048, temperature: float = 0.1):
        self.model_name = model
        self.max_tokens = max_tokens
        self.temperature = temperature
        self._model = None
        self._tokenizer = None

    def load(self) -> None:
        """Load the model into Metal GPU memory."""
        if self._model is not None:
            logger.debug("Model already loaded: %s", self.model_name)
            return

        logger.info("Loading MLX model: %s", self.model_name)
        start = time.monotonic()

        from mlx_lm import load as mlx_load

        # §6c defense-in-depth: apply the shared mlx memory-limit guideline
        # immediately before the model load. On mlx 0.32.0 this is only a
        # guideline (it throws just once exceeded AND RAM+swap are exhausted)
        # and default_memory_limit_bytes() is a no-op when it returns None —
        # never the primary crash mitigation. Guarded so a failure here can
        # never block the actual model load. mlx-only: the gguf/llama-cpp
        # backend manages its own memory and is untouched by
        # mx.set_memory_limit. Only attempted once mlx.core is already
        # resident in sys.modules (the ``mlx_lm`` import above loads it as a
        # side effect) — never an independent trigger for mlx.core's first
        # import, since mlx's nanobind bindings are not safe to import a
        # second time after eviction/reload.
        try:
            if "mlx.core" in sys.modules:
                from speech_stack.memory import apply_memory_policy, default_memory_limit_bytes

                apply_memory_policy(memory_limit_bytes=default_memory_limit_bytes())
        except Exception:
            logger.warning("could not apply mlx memory guideline before LLM model load", exc_info=True)

        self._model, self._tokenizer = mlx_load(self.model_name)

        elapsed = time.monotonic() - start
        logger.info("Model loaded in %.1fs: %s", elapsed, self.model_name)

    def generate(
        self, system_prompt: str, user_content: str, *, response_format: dict[str, Any] | None = None
    ) -> tuple[str, int]:
        """Generate a response from the loaded model.

        Args:
            system_prompt: System instruction for the model.
            user_content: User message content.
            response_format: Optional backend-specific structured-output request.
                MLX does not support constrained decoding, so it is ignored.

        Returns:
            Tuple of (response_text, token_count).

        Raises:
            RuntimeError: If model is not loaded.
        """
        if self._model is None:
            raise RuntimeError("Model not loaded. Call load() first.")

        from mlx_lm import generate as mlx_generate
        from mlx_lm.sample_utils import make_sampler

        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ]

        prompt = self._tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        sampler = make_sampler(temp=self.temperature)

        start = time.monotonic()
        result = mlx_generate(
            self._model,
            self._tokenizer,
            prompt=prompt,
            sampler=sampler,
            max_tokens=self.max_tokens,
            verbose=False,
        )
        elapsed = time.monotonic() - start

        response = str(result)
        token_count = max(1, len(response) // 4)
        logger.debug(
            "Generated %d tokens in %.1fs (%.0f tok/s)",
            token_count,
            elapsed,
            token_count / elapsed if elapsed > 0 else 0,
        )

        return response, token_count

    def close(self) -> None:
        """Unload model and reclaim Metal GPU memory."""
        if self._model is None:
            return

        import mlx.core as mx

        logger.info("Unloading model: %s", self.model_name)
        del self._tokenizer
        del self._model
        self._model = self._tokenizer = None

        gc.collect()
        mx.clear_cache()
        logger.info("Model unloaded, Metal cache cleared")


class GgufBackend:
    """GGUF-based LLM backend using llama-cpp-python.

    Alternative backend for models distributed as GGUF files.
    """

    def __init__(
        self,
        model: str,
        max_tokens: int = 2048,
        temperature: float = 0.1,
        seed: int = 0,
        n_gpu_layers: int = -1,
        n_ctx: int = 4096,
    ):
        self.model_path = model
        self.max_tokens = max_tokens
        self.temperature = temperature
        self.seed = seed
        self.n_gpu_layers = n_gpu_layers
        self.n_ctx = n_ctx
        self._llm = None

    def load(self) -> None:
        """Load the GGUF model."""
        if self._llm is not None:
            logger.debug("Model already loaded: %s", self.model_path)
            return

        if not Path(self.model_path).is_file():
            if self.model_path == DEFAULT_GGUF_MODEL:
                raise FileNotFoundError(
                    f"Default repaired GGUF model not found: {self.model_path}. "
                    "The upstream Gemma-4 GGUF has a known tokenizer defect and is not downloaded automatically. "
                    "See README.md#default-gguf-model-setup and run `mkdir -p ~/models/gemma-4-repaired && "
                    "python -m wilted.gguf_repair --variant e4b /path/to/source.gguf "
                    "~/models/gemma-4-repaired/gemma-4-E4B_q4_0-it-2026-07-15-repaired.gguf` "
                    "with a source GGUF (gguf_repair fails if the destination directory does not exist), "
                    "or explicitly select the MLX backend."
                )
            raise FileNotFoundError(f"GGUF model file not found: {self.model_path}")

        logger.info("Loading GGUF model: %s", self.model_path)
        start = time.monotonic()

        from llama_cpp import Llama

        self._llm = Llama(
            model_path=self.model_path,
            n_gpu_layers=self.n_gpu_layers,
            n_ctx=self.n_ctx,
            verbose=False,
        )

        elapsed = time.monotonic() - start
        logger.info("GGUF model loaded in %.1fs: %s", elapsed, self.model_path)

    def generate(
        self, system_prompt: str, user_content: str, *, response_format: dict[str, Any] | None = None
    ) -> tuple[str, int]:
        """Generate a response from the loaded GGUF model.

        Returns:
            Tuple of (response_text, token_count).

        Raises:
            RuntimeError: If model is not loaded.
        """
        if self._llm is None:
            raise RuntimeError("Model not loaded. Call load() first.")

        start = time.monotonic()
        completion_args: dict[str, Any] = {
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
            "max_tokens": self.max_tokens,
            "temperature": self.temperature,
            "seed": self.seed,
        }
        if response_format is not None:
            completion_args["response_format"] = response_format
        result = self._llm.create_chat_completion(
            **completion_args,
        )
        elapsed = time.monotonic() - start

        response = result["choices"][0]["message"]["content"]
        token_count = result.get("usage", {}).get("completion_tokens", len(response) // 4)

        logger.debug(
            "GGUF generated %d tokens in %.1fs",
            token_count,
            elapsed,
        )

        return response, token_count

    def close(self) -> None:
        """Unload the GGUF model."""
        if self._llm is None:
            return

        logger.info("Unloading GGUF model: %s", self.model_path)
        del self._llm
        self._llm = None
        gc.collect()
        logger.info("GGUF model unloaded")


# Prefix marking a model string as a Hugging Face GGUF spec:
#   "hf:<repo_id>/<filename>"  ->  resolved to a local cached path.
_HF_SPEC_PREFIX = "hf:"


def resolve_gguf_path(repo_id: str, filename: str) -> str:
    """Resolve a Hugging Face GGUF repo + filename to a local cached path.

    Downloads the file into the HF cache on first use and returns its local
    path; subsequent calls resolve offline from the cache. This keeps the
    snapshot hash out of the codebase — never hardcode a cache path.

    Args:
        repo_id: Hugging Face repo id, e.g. ``google/gemma-4-E4B-it-qat-q4_0-gguf``.
        filename: GGUF file within the repo, e.g. ``gemma-4-E4B_q4_0-it.gguf``.

    Returns:
        Absolute path to the cached GGUF file.
    """
    from huggingface_hub import hf_hub_download

    logger.info("Resolving GGUF from Hugging Face: %s/%s", repo_id, filename)
    return hf_hub_download(repo_id=repo_id, filename=filename)


def _resolve_model_spec(model: str) -> str:
    """Resolve an ``hf:<repo_id>/<filename>`` spec to a local GGUF path.

    Any other string (an existing file path) is returned unchanged, so
    ``GgufBackend`` always sees a real path internally.

    Raises:
        ValueError: If an ``hf:`` spec is malformed.
    """
    if not model.startswith(_HF_SPEC_PREFIX):
        return model

    spec = model[len(_HF_SPEC_PREFIX) :]
    repo_id, _, filename = spec.rpartition("/")
    if not repo_id or not filename:
        raise ValueError(f"Invalid HF GGUF spec: '{model}'. Expected 'hf:<repo_id>/<filename>'.")
    return resolve_gguf_path(repo_id, filename)


def create_backend(
    backend_type: str = "gguf",
    *,
    model: str = "",
    max_tokens: int = 2048,
    temperature: float = 0.1,
    **kwargs,
) -> LLMBackend:
    """Factory function to create an LLM backend.

    Args:
        backend_type: 'gguf' (default, llama.cpp) or 'mlx'.
        model: Model identifier. For MLX, a HF repo id. For GGUF, either a
            local ``.gguf`` file path or an ``hf:<repo_id>/<filename>`` spec
            resolved to a local cached path via :func:`resolve_gguf_path`.
        max_tokens: Maximum tokens to generate.
        temperature: Sampling temperature.
        **kwargs: Additional backend-specific arguments.

    Returns:
        An LLMBackend instance.

    Raises:
        ValueError: If backend_type is not recognized.
        ExecutionCapabilityError: When called without PipelineRunner authority.
    """
    from wilted.execution_capability import require_execution_capability

    require_execution_capability()

    if backend_type == "mlx":
        return MlxBackend(model=model, max_tokens=max_tokens, temperature=temperature)
    if backend_type == "gguf":
        return GgufBackend(
            model=_resolve_model_spec(model),
            max_tokens=max_tokens,
            temperature=temperature,
            seed=kwargs.get("seed", 0),
            n_gpu_layers=kwargs.get("n_gpu_layers", -1),
            n_ctx=kwargs.get("n_ctx", 4096),
        )
    raise ValueError(f"Unknown backend type: '{backend_type}'. Use 'gguf' or 'mlx'.")


def parse_json_response(response: str) -> dict | list:
    """Extract and parse JSON from an LLM response.

    Handles common issues: markdown code fences, leading/trailing text.

    Args:
        response: Raw LLM response text.

    Returns:
        Parsed JSON object.

    Raises:
        ValueError: If no valid JSON found in response.
    """
    text = response.strip()

    # Strip markdown code fences
    if "```" in text:
        lines = text.split("\n")
        inside = False
        json_lines = []
        for line in lines:
            if line.strip().startswith("```"):
                inside = not inside
                continue
            if inside:
                json_lines.append(line)
        if json_lines:
            text = "\n".join(json_lines).strip()

    # Try direct parse first
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Try to find JSON object or array in the text, tracking string context
    # so braces inside quoted strings don't confuse the depth counter.
    for start_char, end_char in [("{", "}"), ("[", "]")]:
        start = text.find(start_char)
        if start == -1:
            continue
        depth = 0
        in_string = False
        escape_next = False
        for i in range(start, len(text)):
            ch = text[i]
            if escape_next:
                escape_next = False
                continue
            if ch == "\\":
                escape_next = True
                continue
            if ch == '"':
                in_string = not in_string
                continue
            if in_string:
                continue
            if ch == start_char:
                depth += 1
            elif ch == end_char:
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[start : i + 1])
                    except json.JSONDecodeError:
                        break

    raise ValueError(f"No valid JSON found in LLM response: {text[:200]}")
