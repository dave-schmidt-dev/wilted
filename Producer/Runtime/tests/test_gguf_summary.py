"""Summary-only GGUF admission using the installed formatter and fake inference."""

from dataclasses import replace
from types import SimpleNamespace

import pytest

from wilted.llm import GgufBackend

pytestmark = pytest.mark.unit

TEMPLATE = "{{ bos_token }}{% for m in messages %}<{{ m.role }}>{{ m.content }}{{ eos_token }}{% endfor %}<assistant>"


class FakeModel:
    def __init__(self, *, context=4096, template=TEMPLATE):
        self.metadata = {"tokenizer.chat_template": template}
        self._model = SimpleNamespace(token_get_text=lambda token: {1: "<bos>", 2: "<eos>"}[token])
        self.chat_handler = object()
        self.chat_format = "existing-ad-handler"
        self.context = context
        self.token_calls = []
        self.completions = []
        self.finish_reason = "stop"
        self.text = "Whole transcript summary"
        self.usage_override = None
        self.error = None

    def token_bos(self):
        return 1

    def token_eos(self):
        return 2

    def n_ctx(self):
        return self.context

    def tokenize(self, data, *, add_bos, special):
        self.token_calls.append((data, add_bos, special))
        # Recognize the actual formatter's special token strings, not guessed characters/token.
        data = data.replace(b"<bos>", b"\x01").replace(b"<eos>", b"\x02") if special else data
        return ([1] if add_bos else []) + [b + 10 for b in data]

    def create_completion(self, **kwargs):
        self.completions.append(kwargs)
        if self.error:
            raise self.error
        usage = self.usage_override
        if usage is None:
            usage = {"prompt_tokens": len(kwargs["prompt"]), "completion_tokens": 3}
        result = {
            "id": "fake", "created": 0, "model": "synthetic-local",
            "choices": [{"text": self.text, "logprobs": None, "finish_reason": self.finish_reason}],
            "usage": usage,
        }
        return result


@pytest.fixture
def backend():
    b = GgufBackend(model="never-opened.gguf", max_tokens=32)
    b._llm = FakeModel()
    return b


def test_exact_installed_formatter_overhead_tokenization_and_generation(backend):
    prepared = backend.prepare_summary("Summarize", "α\nMIDDLE\n終")
    assert prepared.output_reserve == 32
    assert prepared.context_size == 4096
    data, add_bos, special = backend._llm.token_calls[-1]
    assert data == "<bos><system>Summarize<eos><user>α\nMIDDLE\n終<eos><assistant>".encode()
    assert (add_bos, special) == (False, True)
    counted_tokens = tuple(backend._llm.tokenize(data, add_bos=add_bos, special=special))
    assert prepared.token_count == len(counted_tokens)
    handler, chat_format = backend._llm.chat_handler, backend._llm.chat_format
    assert backend.generate_summary(prepared) == ("Whole transcript summary", 3)
    call = backend._llm.completions[-1]
    assert tuple(call["prompt"]) == counted_tokens
    assert call["max_tokens"] == 32
    assert call["temperature"] == backend.temperature
    assert call["seed"] == backend.seed
    assert call["stop"] == ["<eos>"]
    assert call["stopping_criteria"] is not None
    assert backend._llm.chat_handler is handler
    assert backend._llm.chat_format == chat_format


def test_render_once_even_for_time_dependent_template(backend, monkeypatch):
    from llama_cpp.llama_chat_format import Jinja2ChatFormatter

    times = iter(["first-time", "second-time"])
    monkeypatch.setattr(Jinja2ChatFormatter, "strftime_now", staticmethod(lambda _: next(times)))
    backend._llm.metadata["tokenizer.chat_template"] = TEMPLATE + "{{ strftime_now('%S') }}"
    prepared = backend.prepare_summary("system", "text")
    first_prompt = backend._llm.token_calls[-1][0]
    assert first_prompt.endswith(b"first-time")
    backend.generate_summary(prepared)
    assert backend._llm.token_calls[-1][0] == first_prompt
    assert next(times) == "second-time"


def test_actual_context_exact_fit_and_no_silent_output_clamp(backend):
    count = backend.prepare_summary("s", "u").token_count
    backend._llm.context = count + backend.max_tokens
    prepared = backend.prepare_summary("s", "u")
    backend.generate_summary(prepared)
    assert backend._llm.completions[-1]["max_tokens"] == 32
    backend._llm.context -= 1
    with pytest.raises(ValueError, match="context"):
        backend.prepare_summary("s", "u")
    assert len(backend._llm.completions) == 1


@pytest.mark.parametrize("reserve", [0, -1, True, 1.5, 4096])
def test_invalid_output_reserve_rejected(backend, reserve):
    backend.max_tokens = reserve
    with pytest.raises(ValueError, match="reserve"):
        backend.prepare_summary("s", "u")


@pytest.mark.parametrize("metadata", [{}, {"tokenizer.chat_template": ""}, {"tokenizer.chat_template": 42}])
def test_missing_or_invalid_metadata_template_fails_without_fallback(backend, metadata):
    backend._llm.metadata = metadata
    with pytest.raises(ValueError, match="template"):
        backend.prepare_summary("s", "u")
    assert backend._llm.completions == []


def test_explicit_named_default_template_supported(backend):
    backend._llm.metadata = {"tokenizer.chat_template.default": TEMPLATE}
    assert backend.prepare_summary("s", "u").token_count > 0


def test_unsupported_template_fails_clearly(backend):
    backend._llm.metadata["tokenizer.chat_template"] = "{{ raise_exception('unsupported roles') }}"
    with pytest.raises(ValueError, match="template"):
        backend.prepare_summary("s", "u")


def test_unloaded_or_reloaded_model_cannot_generate(backend):
    prepared = backend.prepare_summary("s", "u")
    backend._llm = FakeModel()
    with pytest.raises(ValueError, match="model"):
        backend.generate_summary(prepared)
    backend._llm = None
    with pytest.raises(RuntimeError, match="not loaded"):
        backend.prepare_summary("s", "u")
    with pytest.raises(RuntimeError, match="not loaded"):
        backend.generate_summary(prepared)


@pytest.mark.parametrize("reason", ["length", None, "tool_calls"])
def test_truncated_or_missing_finish_reason_never_succeeds(backend, reason):
    prepared = backend.prepare_summary("s", "u")
    backend._llm.finish_reason = reason
    with pytest.raises(ValueError, match="finish"):
        backend.generate_summary(prepared)


@pytest.mark.parametrize("text", [None, "", " \n", 42])
def test_empty_or_nontext_output_rejected(backend, text):
    prepared = backend.prepare_summary("s", "u")
    backend._llm.text = text
    with pytest.raises(ValueError, match="empty|text"):
        backend.generate_summary(prepared)


@pytest.mark.parametrize("usage", [{}, {"completion_tokens": 3}, {"prompt_tokens": 1, "completion_tokens": 3},
                                     {"prompt_tokens": 34, "completion_tokens": True}])
def test_missing_or_mismatched_actual_usage_rejected(backend, usage):
    prepared = backend.prepare_summary("s", "u")
    backend._llm.usage_override = usage
    with pytest.raises(ValueError, match="usage"):
        backend.generate_summary(prepared)


def test_completion_usage_cannot_exceed_reserved_output(backend):
    prepared = backend.prepare_summary("s", "u")
    backend._llm.usage_override = {"prompt_tokens": prepared.token_count, "completion_tokens": 33}
    with pytest.raises(ValueError, match="usage"):
        backend.generate_summary(prepared)


def test_context_changes_and_modified_prepared_count_fail_before_effect(backend):
    prepared = backend.prepare_summary("s", "u")
    with pytest.raises(ValueError, match="prepared"):
        backend.generate_summary(replace(prepared, token_count=prepared.token_count + 1))
    backend._llm.context = 12
    with pytest.raises(ValueError, match="context"):
        backend.generate_summary(prepared)
    assert backend._llm.completions == []


def test_generation_error_is_not_converted_to_success(backend):
    prepared = backend.prepare_summary("s", "u")
    backend._llm.error = RuntimeError("synthetic generation failure")
    with pytest.raises(RuntimeError, match="synthetic generation"):
        backend.generate_summary(prepared)


@pytest.mark.parametrize("tokens", [0, -1, True, None, "3"])
def test_actual_completion_count_must_be_positive_integer(backend, tokens):
    prepared = backend.prepare_summary("s", "u")
    backend._llm.usage_override = {"prompt_tokens": prepared.token_count, "completion_tokens": tokens}
    with pytest.raises(ValueError, match="usage"):
        backend.generate_summary(prepared)


def test_reserve_boundary_stop_is_valid_and_length_is_not(backend):
    prepared = backend.prepare_summary("s", "u")
    backend._llm.usage_override = {"prompt_tokens": prepared.token_count, "completion_tokens": 32}
    assert backend.generate_summary(prepared) == ("Whole transcript summary", 32)
    backend._llm.finish_reason = "length"
    with pytest.raises(ValueError, match="finish"):
        backend.generate_summary(prepared)


def test_prepared_value_is_frozen_and_does_not_retain_closed_model(backend):
    from dataclasses import FrozenInstanceError
    from weakref import ref

    prepared = backend.prepare_summary("s", "u")
    with pytest.raises(FrozenInstanceError):
        prepared.token_count = 1
    reference = ref(backend._llm)
    backend.close()
    assert reference() is None
    assert prepared._model_ref() is None


def test_missing_eos_or_nonmapping_metadata_fails_clearly(backend):
    backend._llm.token_eos = lambda: -1
    with pytest.raises(ValueError, match="template"):
        backend.prepare_summary("s", "u")
    backend._llm.metadata = None
    with pytest.raises(ValueError, match="template"):
        backend.prepare_summary("s", "u")


@pytest.mark.parametrize("field", ["token_count", "output_reserve"])
def test_malformed_prepared_budget_raises_value_error_before_effect(backend, field):
    prepared = backend.prepare_summary("s", "u")
    with pytest.raises(ValueError, match="prepared"):
        backend.generate_summary(replace(prepared, **{field: None}))
    assert backend._llm.completions == []
