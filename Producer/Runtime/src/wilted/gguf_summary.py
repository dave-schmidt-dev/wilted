"""Measured GGUF chat prompts shared by summaries and commercial reviews."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from threading import Lock
from typing import Any
from weakref import ReferenceType, ref


@dataclass(slots=True)
class _PreparedUse:
    lock: Any = field(default_factory=Lock, repr=False)
    consumed: bool = False

    def claim(self) -> None:
        with self.lock:
            if self.consumed:
                raise ValueError("Prepared prompt was already consumed")
            self.consumed = True


@dataclass(frozen=True, slots=True)
class PreparedSummary:
    """One rendered prompt and its model-bound context/output budget.

    The weak model reference permits backend.close() to release the model even
    when a caller retains this value. The SDK formatter response is reused,
    including its stop criteria, so time-dependent templates render only once.
    """

    token_count: int
    context_size: int
    output_reserve: int
    _model_ref: ReferenceType[Any] = field(repr=False)
    _response: Any = field(repr=False)
    _tokens: tuple[int, ...] = field(repr=False)
    _system_prompt: str = field(repr=False)
    _user_content: str = field(repr=False)
    _response_format_json: str | None = field(repr=False)
    _formatter_state: tuple[Any, ...] = field(repr=False)
    _generation_config: tuple[float, int] | None = field(default=None, repr=False)
    _use: _PreparedUse = field(default_factory=_PreparedUse, repr=False, compare=False)


PreparedPrompt = PreparedSummary


class PromptBudgetExceeded(ValueError):
    """A measured prompt and its unchanged output reserve do not fit."""

    def __init__(self, token_count: int, context_size: int, output_reserve: int):
        self.token_count = token_count
        self.context_size = context_size
        self.output_reserve = output_reserve
        super().__init__(
            f"Prompt needs {token_count + output_reserve} tokens "
            f"({token_count} prompt + {output_reserve} output reserve) "
            f"but the model context is {context_size}"
        )


def _positive_integer(value: Any) -> bool:
    return type(value) is int and value > 0


def _loaded(model: Any) -> None:
    if model is None:
        raise RuntimeError("Model not loaded. Call load() first.")


def _tokens(model: Any, response: Any) -> tuple[int, ...]:
    # Match chat_formatter_to_chat_completion_handler exactly; no extra BOS/EOS.
    return tuple(model.tokenize(response.prompt.encode("utf-8"), add_bos=not response.added_special, special=True))


def response_format_snapshot(response_format: dict[str, Any] | None) -> str | None:
    """Bind a structured response request without retaining its mutable dictionary."""
    if response_format is None:
        return None
    return json.dumps(response_format, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _formatter_state(model: Any) -> tuple[Any, ...]:
    metadata = model.metadata
    if not isinstance(metadata, dict):
        raise ValueError("Prompt requires model chat template metadata")
    template = metadata.get("tokenizer.chat_template") or metadata.get("tokenizer.chat_template.default")
    if not isinstance(template, str) or not template.strip():
        raise ValueError("Prompt requires an actual model chat template")
    eos_id, bos_id = model.token_eos(), model.token_bos()
    if type(eos_id) is not int or eos_id < 0:
        raise ValueError("Model has no EOS token")
    eos_text = model._model.token_get_text(eos_id)
    bos_text = model._model.token_get_text(bos_id) if bos_id != -1 else ""
    if not isinstance(eos_text, str) or not eos_text:
        raise ValueError("Model has no EOS text")
    return (template, eos_id, bos_id, eos_text, bos_text,
            getattr(model, "chat_format", None), id(getattr(model, "chat_handler", None)))


def _prepare_prompt(
    model: Any,
    system_prompt: str,
    user_content: str,
    output_reserve: int,
    *,
    response_format: dict[str, Any] | None,
) -> PreparedSummary:
    """Render/count one actual metadata-template prompt without inference."""
    _loaded(model)
    context_size = model.n_ctx()
    if not _positive_integer(context_size):
        raise ValueError("Prompt context size must be a positive integer")
    if not _positive_integer(output_reserve) or output_reserve >= context_size:
        raise ValueError("Prompt output reserve must be positive and smaller than context")
    if not all(isinstance(text, str) and text.strip() for text in (system_prompt, user_content)):
        raise ValueError("Prompt messages must be nonblank text")
    metadata = model.metadata
    if not isinstance(metadata, dict):
        raise ValueError("Prompt requires model chat template metadata")
    template = metadata.get("tokenizer.chat_template") or metadata.get("tokenizer.chat_template.default")
    if not isinstance(template, str) or not template.strip():
        raise ValueError("Prompt requires an actual model chat template")

    from llama_cpp.llama_chat_format import Jinja2ChatFormatter

    try:
        eos_id, bos_id = model.token_eos(), model.token_bos()
        # Mirror installed Llama's metadata formatter setup. No format guessing,
        # instance chat_handler mutation or empty EOS stop string is permitted.
        if type(eos_id) is not int or eos_id < 0:
            raise ValueError("Model has no EOS token")
        eos_text = model._model.token_get_text(eos_id)
        bos_text = model._model.token_get_text(bos_id) if bos_id != -1 else ""
        if not isinstance(eos_text, str) or not eos_text:
            raise ValueError("Model has no EOS text")
        formatter = Jinja2ChatFormatter(template, eos_text, bos_text, stop_token_ids=[eos_id])
        messages = [{"role": "system", "content": system_prompt}, {"role": "user", "content": user_content}]
        # The installed handler consumes response_format as grammar, not template input.
        response = formatter(messages=messages)
        tokens = _tokens(model, response)
    except Exception:
        # The cause may contain model/template text; keep the public failure terse.
        raise ValueError("Unsupported model chat template") from None
    if not tokens:
        raise ValueError("Prompt rendered no tokens")
    return PreparedSummary(
        len(tokens), context_size, output_reserve, ref(model), response, tokens,
        system_prompt, user_content, response_format_snapshot(response_format), _formatter_state(model),
    )


def measure_prompt(
    model: Any,
    system_prompt: str,
    user_content: str,
    output_reserve: int,
    *,
    response_format: dict[str, Any] | None = None,
) -> PreparedPrompt:
    """Measure the exact prompt the loaded model would receive, without inference.

    Structured response formats bind the later grammar without changing template
    input, matching the installed handler. The output reserve is never reduced.

    Raises:
        RuntimeError: The backend has no loaded model.
        PromptBudgetExceeded: The measured prompt plus output reserve does not fit.
        ValueError: Template, messages, reserve or measured budget is unusable.
    """
    prepared = _prepare_prompt(model, system_prompt, user_content, output_reserve, response_format=response_format)
    if prepared.token_count + prepared.output_reserve > prepared.context_size:
        raise PromptBudgetExceeded(prepared.token_count, prepared.context_size, prepared.output_reserve)
    return prepared


def prepare_summary(model: Any, system_prompt: str, user_content: str, output_reserve: int) -> PreparedSummary:
    """Render/count an actual metadata template and reject an unfit summary.

    Raises:
        RuntimeError: The backend has no loaded model.
        ValueError: Template, messages, reserve or actual context is unusable.
    """
    return measure_prompt(model, system_prompt, user_content, output_reserve)


def generate_prepared_prompt(
    model: Any, prepared: PreparedSummary, *, temperature: float, seed: int, single_use: bool = True
) -> tuple[str, int]:
    """Generate from the counted prompt, requiring actual complete output usage.

    Raises:
        RuntimeError: The model is not loaded or inference fails.
        ValueError: Prepared identity/context, finish status, output or usage fails.
    """
    _loaded(model)
    if not isinstance(prepared, PreparedSummary) or prepared._model_ref() is not model:
        raise ValueError("Summary prepared for a different or unloaded model")
    if not _positive_integer(prepared.token_count) or not _positive_integer(prepared.output_reserve):
        raise ValueError("Summary prepared prompt budget changed")
    context_size = model.n_ctx()
    if (not _positive_integer(context_size) or context_size != prepared.context_size
            or prepared.token_count + prepared.output_reserve > context_size):
        raise ValueError("Summary actual context changed after preparation")
    if prepared.token_count != len(prepared._tokens) or _tokens(model, prepared._response) != prepared._tokens:
        raise ValueError("Summary prepared prompt budget changed")

    if _formatter_state(model) != prepared._formatter_state:
        raise ValueError("Prepared formatter configuration changed")
    if single_use:
        prepared._use.claim()
    response_format = (json.loads(prepared._response_format_json)
                       if prepared._response_format_json is not None else None)

    from llama_cpp.llama_chat_format import chat_formatter_to_chat_completion_handler

    # Returning the already-rendered response avoids a second strftime_now call.
    handler = chat_formatter_to_chat_completion_handler(lambda **_: prepared._response)
    result = handler(llama=model, messages=[], max_tokens=prepared.output_reserve,
                     temperature=temperature, seed=seed, stream=False, response_format=response_format)
    choices = result.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise ValueError("Summary missing finish status")
    choice = choices[0]
    if choice.get("finish_reason") != "stop":
        raise ValueError("Summary incomplete finish status (output may be truncated)")
    message = choice.get("message")
    text = message.get("content") if isinstance(message, dict) else None
    if not isinstance(text, str) or not text.strip():
        raise ValueError("Summary output is empty or not text")
    usage = result.get("usage")
    if not isinstance(usage, dict):
        raise ValueError("Summary requires actual token usage")
    prompt_tokens, completion_tokens = usage.get("prompt_tokens"), usage.get("completion_tokens")
    if (type(prompt_tokens) is not int or prompt_tokens != prepared.token_count
            or not _positive_integer(completion_tokens) or completion_tokens > prepared.output_reserve):
        raise ValueError("Summary actual token usage does not match prepared budget")
    return text, completion_tokens


def generate_summary(model: Any, prepared: PreparedSummary, *, temperature: float, seed: int) -> tuple[str, int]:
    """Generate a summary with its existing frozen-render and completion checks."""
    if not isinstance(prepared, PreparedSummary) or prepared._response_format_json is not None:
        raise ValueError("Summary requires its own prepared request")
    return generate_prepared_prompt(model, prepared, temperature=temperature, seed=seed, single_use=False)
