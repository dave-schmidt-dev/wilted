"""Measured, summary-only GGUF chat prompts; generic ad generation is unchanged."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any
from weakref import ReferenceType, ref


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


def _positive_integer(value: Any) -> bool:
    return type(value) is int and value > 0


def _loaded(model: Any) -> None:
    if model is None:
        raise RuntimeError("Model not loaded. Call load() first.")


def _tokens(model: Any, response: Any) -> tuple[int, ...]:
    # Match chat_formatter_to_chat_completion_handler exactly; no extra BOS/EOS.
    return tuple(model.tokenize(response.prompt.encode("utf-8"), add_bos=not response.added_special, special=True))


def prepare_summary(model: Any, system_prompt: str, user_content: str, output_reserve: int) -> PreparedSummary:
    """Render/count an actual metadata template and reject an unfit summary.

    Raises:
        RuntimeError: The backend has no loaded model.
        ValueError: Template, messages, reserve or actual context is unusable.
    """
    _loaded(model)
    context_size = model.n_ctx()
    if not _positive_integer(context_size):
        raise ValueError("Summary context size must be a positive integer")
    if not _positive_integer(output_reserve) or output_reserve >= context_size:
        raise ValueError("Summary output reserve must be positive and smaller than context")
    if not all(isinstance(text, str) and text.strip() for text in (system_prompt, user_content)):
        raise ValueError("Summary messages must be nonblank text")
    metadata = model.metadata
    if not isinstance(metadata, dict):
        raise ValueError("Summary requires model chat template metadata")
    template = metadata.get("tokenizer.chat_template") or metadata.get("tokenizer.chat_template.default")
    if not isinstance(template, str) or not template.strip():
        raise ValueError("Summary requires an actual model chat template")

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
        response = formatter(messages=[{"role": "system", "content": system_prompt},
                                       {"role": "user", "content": user_content}])
        tokens = _tokens(model, response)
    except Exception:
        # The cause may contain model/template text; keep the public failure terse.
        raise ValueError("Unsupported summary model chat template") from None
    if not tokens or len(tokens) + output_reserve > context_size:
        raise ValueError("Summary prompt and output reserve exceed actual context")
    return PreparedSummary(len(tokens), context_size, output_reserve, ref(model), response, tokens)


def generate_summary(model: Any, prepared: PreparedSummary, *, temperature: float, seed: int) -> tuple[str, int]:
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

    from llama_cpp.llama_chat_format import chat_formatter_to_chat_completion_handler

    # Returning the already-rendered response avoids a second strftime_now call.
    handler = chat_formatter_to_chat_completion_handler(lambda **_: prepared._response)
    result = handler(llama=model, messages=[], max_tokens=prepared.output_reserve,
                     temperature=temperature, seed=seed, stream=False)
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
