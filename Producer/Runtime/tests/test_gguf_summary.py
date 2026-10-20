"""Summary-only GGUF admission using the installed formatter and fake inference."""

from dataclasses import replace
from types import SimpleNamespace

import pytest

from wilted.gguf_summary import PromptBudgetExceeded
from wilted.llm import GgufBackend

pytestmark = pytest.mark.unit

TEMPLATE = "{{ bos_token }}{% for m in messages %}<{{ m.role }}>{{ m.content }}{{ eos_token }}{% endfor %}<assistant>"


class FakeModel:
    def __init__(self, *, context=4096, template=TEMPLATE):
        self.metadata = {"tokenizer.chat_template": template}
        self.verbose = False
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


def test_prepared_commercial_matches_installed_formatter_and_grammar(backend):
    from llama_cpp.llama_chat_format import Jinja2ChatFormatter, chat_formatter_to_chat_completion_handler

    backend._llm.metadata["tokenizer.chat_template"] = (
        TEMPLATE + "{% if response_format %}<schema>unexpected</schema>{% endif %}"
    )
    schema = {"type": "json_object", "schema": {"type": "object"}}
    prepared = backend.measure_prompt("system", "text", response_format=schema)
    assert b"<schema>" not in backend._llm.token_calls[-1][0]
    formatter = Jinja2ChatFormatter(backend._llm.metadata["tokenizer.chat_template"],
                                   "<eos>", "<bos>", stop_token_ids=[2])
    handler = chat_formatter_to_chat_completion_handler(formatter)
    handler(llama=backend._llm, messages=[{"role": "system", "content": "system"},
            {"role": "user", "content": "text"}], max_tokens=backend.max_tokens,
            temperature=backend.temperature, seed=backend.seed, stream=False, response_format=schema)
    ordinary = backend._llm.completions[-1]
    assert backend.generate("system", "text", response_format=schema, prepared_prompt=prepared) == (
        "Whole transcript summary", 3
    )
    actual = backend._llm.completions[-1]
    assert tuple(actual["prompt"]) == tuple(ordinary["prompt"]) == prepared._tokens
    assert actual["grammar"] is not None
    assert actual["max_tokens"] == backend.max_tokens


def test_measured_budget_uses_actual_tokens_and_unchanged_output_reserve(backend):
    plain = backend.measure_prompt("s", "u")
    backend._llm.context = plain.token_count + backend.max_tokens
    schema = {"type": "json_object", "schema": {"type": "object"}}
    measured = backend.measure_prompt("s", "u", response_format=schema)
    assert measured.token_count == plain.token_count
    assert measured.output_reserve == backend.max_tokens
    backend._llm.context -= 1
    with pytest.raises(PromptBudgetExceeded) as raised:
        backend.measure_prompt("s", "u", response_format=schema)
    assert raised.value.token_count == plain.token_count
    assert raised.value.context_size == backend._llm.context
    assert raised.value.output_reserve == backend.max_tokens
    assert backend._llm.completions == []


def test_prepared_commercial_renders_once_and_is_single_use(backend, monkeypatch):
    from llama_cpp.llama_chat_format import Jinja2ChatFormatter

    times = iter(["first-render", "second-render"])
    monkeypatch.setattr(Jinja2ChatFormatter, "strftime_now", staticmethod(lambda _: next(times)))
    backend._llm.metadata["tokenizer.chat_template"] = TEMPLATE + "{{ strftime_now('%S') }}"
    prepared = backend.measure_prompt("system", "text")
    first_prompt = backend._llm.token_calls[-1][0]
    assert first_prompt.endswith(b"first-render")
    backend.generate("system", "text", prepared_prompt=prepared)
    assert tuple(backend._llm.completions[-1]["prompt"]) == prepared._tokens
    assert next(times) == "second-render"
    with pytest.raises(ValueError, match="consumed"):
        backend.generate("system", "text", prepared_prompt=prepared)
    assert len(backend._llm.completions) == 1


@pytest.mark.parametrize("changed", ["model", "context", "reserve", "template", "handler", "seed", "temperature",
                                     "system", "user", "format", "tokens"])
def test_stale_prepared_commercial_rejected_before_inference(backend, changed):
    schema = {"type": "json_object", "schema": {"type": "object"}}
    prepared = backend.measure_prompt("system", "text", response_format=schema)
    original_model = backend._llm
    system, user = "system", "text"
    if changed == "model":
        backend._llm = FakeModel()
    elif changed == "context":
        backend._llm.context += 1
    elif changed == "reserve":
        backend.max_tokens += 1
    elif changed == "template":
        backend._llm.metadata["tokenizer.chat_template"] += "changed"
    elif changed == "handler":
        backend._llm.chat_handler = object()
    elif changed == "seed":
        backend.seed += 1
    elif changed == "temperature":
        backend.temperature += 0.1
    elif changed == "system":
        system = "different system"
    elif changed == "user":
        user = "different text"
    elif changed == "format":
        schema["schema"]["description"] = "changed after preparation"
    else:
        prepared = replace(prepared, _tokens=prepared._tokens + (999,))
    with pytest.raises(ValueError):
        backend.generate(system, user, response_format=schema, prepared_prompt=prepared)
    assert original_model.completions == []
    assert backend._llm.completions == []


def test_prepared_commercial_consumption_is_atomic(backend):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Barrier

    prepared = backend.measure_prompt("system", "text")
    barrier = Barrier(2)
    def generate(_):
        barrier.wait(timeout=5)
        try:
            backend.generate("system", "text", prepared_prompt=prepared)
            return "generated"
        except ValueError as error:
            assert "consumed" in str(error)
            return "refused"
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(generate, range(2))) == ["generated", "refused"]
    assert len(backend._llm.completions) == 1


def test_ordinary_generation_keeps_existing_arguments(backend):
    calls = []
    def ordinary(**kwargs):
        calls.append(kwargs)
        return {"choices": [{"message": {"content": "ordinary response"}}],
                "usage": {"completion_tokens": 2}}
    backend._llm.create_chat_completion = ordinary
    schema = {"type": "json_object"}
    assert backend.generate("system", "text", response_format=schema) == ("ordinary response", 2)
    assert calls == [{"messages": [{"role": "system", "content": "system"},
                                  {"role": "user", "content": "text"}],
                      "max_tokens": backend.max_tokens, "temperature": backend.temperature,
                      "seed": backend.seed, "response_format": schema}]
    assert backend._llm.completions == []


def test_measure_prompt_keeps_summary_generation_and_reserve_unchanged(backend):
    handler, chat_format = backend._llm.chat_handler, backend._llm.chat_format
    measured = backend.measure_prompt("Summarize", "whole transcript")
    prepared = backend.prepare_summary("Summarize", "whole transcript")
    assert (measured.token_count, measured.context_size, measured.output_reserve) == (
        prepared.token_count, prepared.context_size, prepared.output_reserve
    )
    assert backend._llm.chat_handler is handler
    assert backend._llm.chat_format == chat_format
    assert backend.generate_summary(prepared) == ("Whole transcript summary", 3)
    assert backend._llm.completions[-1]["max_tokens"] == backend.max_tokens
    backend.max_tokens = 0
    with pytest.raises(ValueError, match="reserve"):
        backend.measure_prompt("s", "u")
    assert len(backend._llm.completions) == 1


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
