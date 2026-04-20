"""LLM backend interface — protocol and implementations for local model inference.

Follows scarecrow's architecture: load once, generate many, close once.
Only one model loaded at a time; explicit unloading reclaims Metal GPU memory.

Usage:
    from wilted.llm import create_backend

    backend = create_backend("mlx", model="mlx-community/gemma-4-e4b-it-4bit")
    backend.load()
    response, tokens = backend.generate("You are a classifier.", "Classify this text.")
    backend.close()
"""

from __future__ import annotations

import gc
import json
import logging
import time
from typing import Protocol, runtime_checkable

logger = logging.getLogger(__name__)


@runtime_checkable
class LLMBackend(Protocol):
    """Protocol for local LLM inference backends.

    Each backend manages a single model. The lifecycle is:
    1. load() — load model into memory (GPU/CPU)
    2. generate() — run inference (may be called many times)
    3. close() — unload model and reclaim memory
    """

    def load(self) -> None: ...

    def generate(self, system_prompt: str, user_content: str) -> tuple[str, int]: ...

    def close(self) -> None: ...


class MlxBackend:
    """MLX-based LLM backend using mlx-vlm (or mlx-lm).

    Loads a Hugging Face model via mlx_vlm.generate and manages Metal GPU memory.
    """

    def __init__(self, model: str, max_tokens: int = 2048, temperature: float = 0.1):
        self.model_name = model
        self.max_tokens = max_tokens
        self.temperature = temperature
        self._model = None
        self._tokenizer = None
        self._processor = None

    def load(self) -> None:
        """Load the model into Metal GPU memory."""
        if self._model is not None:
            logger.debug("Model already loaded: %s", self.model_name)
            return

        logger.info("Loading MLX model: %s", self.model_name)
        start = time.monotonic()

        from mlx_vlm import load as mlx_load

        self._model, self._processor = mlx_load(self.model_name)
        # mlx_vlm.load returns (model, processor); tokenizer is on processor
        self._tokenizer = self._processor

        elapsed = time.monotonic() - start
        logger.info("Model loaded in %.1fs: %s", elapsed, self.model_name)

    def generate(self, system_prompt: str, user_content: str) -> tuple[str, int]:
        """Generate a response from the loaded model.

        Args:
            system_prompt: System instruction for the model.
            user_content: User message content.

        Returns:
            Tuple of (response_text, token_count).

        Raises:
            RuntimeError: If model is not loaded.
        """
        if self._model is None:
            raise RuntimeError("Model not loaded. Call load() first.")

        from mlx_vlm import generate as mlx_generate

        messages = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ]

        # Apply chat template via processor/tokenizer
        prompt = self._processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)

        start = time.monotonic()
        result = mlx_generate(
            self._model,
            self._processor,
            prompt=prompt,
            max_tokens=self.max_tokens,
            temp=self.temperature,
            verbose=False,
        )
        elapsed = time.monotonic() - start

        # mlx_vlm >=0.2 returns a GenerationResult dataclass; older versions return str
        if hasattr(result, "text"):
            response = result.text
            token_count = getattr(result, "total_tokens", None) or max(1, len(response) // 4)
        else:
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
        # Delete processor first — _tokenizer is an alias for the same object,
        # so we must drop the real reference before gc can reclaim Metal memory.
        del self._processor
        del self._tokenizer
        del self._model
        self._model = self._tokenizer = self._processor = None

        gc.collect()
        mx.metal.clear_cache()
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
        n_gpu_layers: int = -1,
        n_ctx: int = 4096,
    ):
        self.model_path = model
        self.max_tokens = max_tokens
        self.temperature = temperature
        self.n_gpu_layers = n_gpu_layers
        self.n_ctx = n_ctx
        self._llm = None

    def load(self) -> None:
        """Load the GGUF model."""
        if self._llm is not None:
            logger.debug("Model already loaded: %s", self.model_path)
            return

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

    def generate(self, system_prompt: str, user_content: str) -> tuple[str, int]:
        """Generate a response from the loaded GGUF model.

        Returns:
            Tuple of (response_text, token_count).

        Raises:
            RuntimeError: If model is not loaded.
        """
        if self._llm is None:
            raise RuntimeError("Model not loaded. Call load() first.")

        start = time.monotonic()
        result = self._llm.create_chat_completion(
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
            max_tokens=self.max_tokens,
            temperature=self.temperature,
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


def create_backend(
    backend_type: str = "mlx",
    *,
    model: str = "",
    max_tokens: int = 2048,
    temperature: float = 0.1,
    **kwargs,
) -> LLMBackend:
    """Factory function to create an LLM backend.

    Args:
        backend_type: 'mlx' or 'gguf'.
        model: Model identifier (HF repo for MLX, file path for GGUF).
        max_tokens: Maximum tokens to generate.
        temperature: Sampling temperature.
        **kwargs: Additional backend-specific arguments.

    Returns:
        An LLMBackend instance.

    Raises:
        ValueError: If backend_type is not recognized.
    """
    if backend_type == "mlx":
        return MlxBackend(model=model, max_tokens=max_tokens, temperature=temperature)
    if backend_type == "gguf":
        return GgufBackend(
            model=model,
            max_tokens=max_tokens,
            temperature=temperature,
            n_gpu_layers=kwargs.get("n_gpu_layers", -1),
            n_ctx=kwargs.get("n_ctx", 4096),
        )
    raise ValueError(f"Unknown backend type: '{backend_type}'. Use 'mlx' or 'gguf'.")


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
