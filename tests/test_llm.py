"""Tests for Phase 2 — LLM backend interface (llm.py)."""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from wilted.llm import (
    GgufBackend,
    MlxBackend,
    _resolve_model_spec,
    create_backend,
    parse_json_response,
    resolve_gguf_path,
)

# ---------------------------------------------------------------------------
# parse_json_response
# ---------------------------------------------------------------------------


class TestParseJsonResponse:
    def test_plain_json_object(self):
        result = parse_json_response('{"key": "value"}')
        assert result == {"key": "value"}

    def test_plain_json_array(self):
        result = parse_json_response("[1, 2, 3]")
        assert result == [1, 2, 3]

    def test_json_with_markdown_fences(self):
        text = '```json\n{"playlist": "Work"}\n```'
        result = parse_json_response(text)
        assert result == {"playlist": "Work"}

    def test_json_with_surrounding_text(self):
        text = 'Here is the result:\n{"playlist": "Fun", "score": 0.8}\nDone.'
        result = parse_json_response(text)
        assert result == {"playlist": "Fun", "score": 0.8}

    def test_nested_json(self):
        text = '{"outer": {"inner": [1, 2]}}'
        result = parse_json_response(text)
        assert result == {"outer": {"inner": [1, 2]}}

    def test_no_json_raises(self):
        with pytest.raises(ValueError, match="No valid JSON"):
            parse_json_response("This is just plain text.")

    def test_empty_string_raises(self):
        with pytest.raises(ValueError, match="No valid JSON"):
            parse_json_response("")

    def test_json_with_whitespace(self):
        text = '  \n  {"key": "value"}  \n  '
        result = parse_json_response(text)
        assert result == {"key": "value"}

    def test_classification_response(self):
        text = '{"playlist": "Education", "relevance_score": 0.75, "summary": "An article about science."}'
        result = parse_json_response(text)
        assert result["playlist"] == "Education"
        assert result["relevance_score"] == 0.75

    def test_braces_inside_string_values(self):
        text = 'Here: {"summary": "The {curly braces} article", "score": 1}'
        result = parse_json_response(text)
        assert result["summary"] == "The {curly braces} article"
        assert result["score"] == 1

    def test_markdown_with_language_tag(self):
        text = '```json\n{"a": 1}\n```'
        result = parse_json_response(text)
        assert result == {"a": 1}

    def test_bare_code_fence(self):
        text = '```\n{"b": 2}\n```'
        result = parse_json_response(text)
        assert result == {"b": 2}


# ---------------------------------------------------------------------------
# create_backend factory
# ---------------------------------------------------------------------------


class TestCreateBackend:
    pytestmark = pytest.mark.usefixtures("execution_capability")

    def test_create_mlx(self):
        backend = create_backend("mlx", model="test-model")
        assert isinstance(backend, MlxBackend)
        assert backend.model_name == "test-model"

    def test_create_gguf(self):
        backend = create_backend("gguf", model="/path/to/model.gguf")
        assert isinstance(backend, GgufBackend)
        assert backend.model_path == "/path/to/model.gguf"

    def test_default_backend_is_gguf(self):
        # llama.cpp GGUF is the default backend after the MLX migration.
        backend = create_backend(model="/path/to/model.gguf")
        assert isinstance(backend, GgufBackend)
        assert backend.model_path == "/path/to/model.gguf"

    def test_create_unknown_raises(self):
        with pytest.raises(ValueError, match="Unknown backend"):
            create_backend("openai", model="gpt-4")

    def test_mlx_default_params(self):
        backend = create_backend("mlx", model="m")
        assert backend.max_tokens == 2048
        assert backend.temperature == 0.1

    def test_custom_params(self):
        backend = create_backend(
            "mlx",
            model="m",
            max_tokens=512,
            temperature=0.5,
        )
        assert backend.max_tokens == 512
        assert backend.temperature == 0.5

    def test_gguf_custom_params(self):
        backend = create_backend(
            "gguf",
            model="/path/m.gguf",
            n_gpu_layers=0,
            n_ctx=8192,
            seed=17,
        )
        assert backend.n_gpu_layers == 0
        assert backend.n_ctx == 8192
        assert backend.seed == 17

    def test_gguf_default_seed_is_fixed(self):
        backend = create_backend("gguf", model="/path/m.gguf")

        assert backend.seed == 0

    def test_mlx_factory_ignores_gguf_seed_without_changing_protocol(self):
        backend = create_backend("mlx", model="m", seed=17)

        assert isinstance(backend, MlxBackend)
        assert not hasattr(backend, "seed")


# ---------------------------------------------------------------------------
# Protocol conformance
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# MlxBackend without loading
# ---------------------------------------------------------------------------


class TestMlxBackendNoModel:
    def test_generate_before_load_raises(self):
        backend = MlxBackend(model="test")
        with pytest.raises(RuntimeError, match="not loaded"):
            backend.generate("system", "user")

    def test_close_without_load_is_noop(self):
        backend = MlxBackend(model="test")
        backend.close()  # Should not raise

    def test_load_sets_model_name(self):
        backend = MlxBackend(model="my-model")
        assert backend.model_name == "my-model"
        assert backend._model is None


class TestGgufBackendNoModel:
    def test_generate_before_load_raises(self):
        backend = GgufBackend(model="test.gguf")
        with pytest.raises(RuntimeError, match="not loaded"):
            backend.generate("system", "user")

    def test_close_without_load_is_noop(self):
        backend = GgufBackend(model="test.gguf")
        backend.close()  # Should not raise

    def test_missing_default_model_fails_with_in_repo_repair_instructions(self, monkeypatch, tmp_path):
        missing_default = tmp_path / "missing-repaired.gguf"
        monkeypatch.setattr("wilted.llm.DEFAULT_GGUF_MODEL", str(missing_default))
        backend = GgufBackend(model=str(missing_default))

        with pytest.raises(FileNotFoundError, match="README.md#default-gguf-model-setup") as exc_info:
            backend.load()

        assert "python -m wilted.gguf_repair" in str(exc_info.value)
        assert "known tokenizer defect" in str(exc_info.value)

    def test_missing_custom_model_fails_before_llama_import(self, tmp_path):
        backend = GgufBackend(model=str(tmp_path / "missing.gguf"))

        with pytest.raises(FileNotFoundError, match="GGUF model file not found"):
            backend.load()

    def test_generate_forwards_optional_response_format(self):
        backend = GgufBackend(model="test.gguf")
        backend._llm = MagicMock()
        backend._llm.create_chat_completion.return_value = {
            "choices": [{"message": {"content": '{"ads":[]}'}}],
            "usage": {"completion_tokens": 2},
        }
        response_format = {"type": "json_object", "schema": {"type": "object"}}

        assert backend.generate("system", "user", response_format=response_format) == ('{"ads":[]}', 2)
        backend._llm.create_chat_completion.assert_called_once_with(
            messages=[{"role": "system", "content": "system"}, {"role": "user", "content": "user"}],
            max_tokens=2048,
            temperature=0.1,
            seed=0,
            response_format=response_format,
        )

    def test_generate_forwards_custom_seed(self):
        backend = GgufBackend(model="test.gguf", seed=23)
        backend._llm = MagicMock()
        backend._llm.create_chat_completion.return_value = {
            "choices": [{"message": {"content": "classified"}}],
            "usage": {"completion_tokens": 3},
        }

        assert backend.generate("system", "user") == ("classified", 3)
        assert backend._llm.create_chat_completion.call_args.kwargs["seed"] == 23
        assert backend._llm.create_chat_completion.call_args.kwargs["temperature"] == 0.1


# ---------------------------------------------------------------------------
# Mock-based integration test
# ---------------------------------------------------------------------------


class TestMlxBackendMocked:
    """Test MlxBackend with mocked mlx_lm imports."""

    def test_load_generate_close_cycle(self, monkeypatch):
        """Full lifecycle with mocked model."""
        import sys
        import types

        mock_mlx_lm = types.ModuleType("mlx_lm")
        mock_mlx_lm.__path__ = []
        mock_sample_utils = types.ModuleType("mlx_lm.sample_utils")

        class MockTokenizer:
            def apply_chat_template(self, messages, **kwargs):
                return "formatted prompt"

        mock_model = object()
        mock_tokenizer = MockTokenizer()

        mock_mlx_lm.load = lambda model_name: (mock_model, mock_tokenizer)
        mock_mlx_lm.generate = lambda model, tokenizer, **kwargs: (
            '{"playlist": "Work", "relevance_score": 0.9, "summary": "Test."}'
        )
        mock_sample_utils.make_sampler = lambda **kwargs: object()

        monkeypatch.setitem(sys.modules, "mlx_lm", mock_mlx_lm)
        monkeypatch.setitem(sys.modules, "mlx_lm.sample_utils", mock_sample_utils)

        # Create mock mlx.core module for close()
        mock_mlx = types.ModuleType("mlx")
        mock_mlx_core = types.ModuleType("mlx.core")

        # close() calls the top-level mx.clear_cache() (mlx 0.32.0 canonical API;
        # the mlx.core.metal.* shims were deprecated and replaced repo-wide).
        mock_mlx_core.clear_cache = lambda: None
        mock_mlx.core = mock_mlx_core
        monkeypatch.setitem(sys.modules, "mlx", mock_mlx)
        monkeypatch.setitem(sys.modules, "mlx.core", mock_mlx_core)

        backend = MlxBackend(model="test-model")
        backend.load()
        assert backend._model is not None

        response, tokens = backend.generate("system", "user")
        assert "Work" in response
        assert tokens > 0

        backend.close()
        assert backend._model is None

    def test_generate_uses_tokenizer_template_and_sampler(self, monkeypatch):
        """MLX-LM generation formats text chat and forwards its sampler."""
        import sys
        import types

        mock_mlx_lm = types.ModuleType("mlx_lm")
        mock_mlx_lm.__path__ = []
        mock_sample_utils = types.ModuleType("mlx_lm.sample_utils")
        mock_generate = MagicMock(return_value="classified")
        mock_sampler = object()
        mock_make_sampler = MagicMock(return_value=mock_sampler)
        mock_mlx_lm.generate = mock_generate
        mock_sample_utils.make_sampler = mock_make_sampler
        monkeypatch.setitem(sys.modules, "mlx_lm", mock_mlx_lm)
        monkeypatch.setitem(sys.modules, "mlx_lm.sample_utils", mock_sample_utils)

        backend = MlxBackend(model="test-model", max_tokens=321, temperature=0.25)
        backend._model = object()
        backend._tokenizer = MagicMock()
        backend._tokenizer.apply_chat_template.return_value = "formatted prompt"

        response, tokens = backend.generate("system", "user")

        assert (response, tokens) == ("classified", 2)
        backend._tokenizer.apply_chat_template.assert_called_once_with(
            [
                {"role": "system", "content": "system"},
                {"role": "user", "content": "user"},
            ],
            tokenize=False,
            add_generation_prompt=True,
        )
        mock_make_sampler.assert_called_once_with(temp=0.25)
        mock_generate.assert_called_once_with(
            backend._model,
            backend._tokenizer,
            prompt="formatted prompt",
            sampler=mock_sampler,
            max_tokens=321,
            verbose=False,
        )

    def test_load_applies_memory_guideline(self, monkeypatch):
        """§6c defense-in-depth: load() applies the shared mlx memory
        guideline immediately before the mlx_lm model load.

        The guideline is only attempted once ``mlx.core`` is already resident
        in ``sys.modules`` (see the comment at the call site in llm.py), so
        this test seeds a fake ``mlx.core`` alongside the fake ``mlx_lm`` —
        mirroring how the real ``mlx_lm`` import loads the real mlx.core as a
        side effect in production.
        """
        import sys
        import types

        mock_mlx_lm = types.ModuleType("mlx_lm")

        class MockTokenizer:
            def apply_chat_template(self, messages, **kwargs):
                return "formatted prompt"

        mock_model = object()
        mock_tokenizer = MockTokenizer()
        mock_mlx_lm.load = lambda model_name: (mock_model, mock_tokenizer)
        monkeypatch.setitem(sys.modules, "mlx_lm", mock_mlx_lm)
        monkeypatch.setitem(sys.modules, "mlx.core", types.ModuleType("mlx.core"))

        mock_default = MagicMock(return_value=54321)
        mock_apply = MagicMock()
        monkeypatch.setattr("speech_stack.memory.default_memory_limit_bytes", mock_default)
        monkeypatch.setattr("speech_stack.memory.apply_memory_policy", mock_apply)

        backend = MlxBackend(model="test-model")
        backend.load()

        mock_default.assert_called_once_with()
        mock_apply.assert_called_once_with(memory_limit_bytes=54321)
        assert backend._model is not None

    def test_load_proceeds_when_memory_guideline_raises(self, monkeypatch):
        """A raising memory guideline must be swallowed — load() still
        succeeds. This is defense-in-depth and must never become a new
        failure mode."""
        import sys
        import types

        mock_mlx_lm = types.ModuleType("mlx_lm")

        class MockTokenizer:
            def apply_chat_template(self, messages, **kwargs):
                return "formatted prompt"

        mock_model = object()
        mock_tokenizer = MockTokenizer()
        mock_mlx_lm.load = lambda model_name: (mock_model, mock_tokenizer)
        monkeypatch.setitem(sys.modules, "mlx_lm", mock_mlx_lm)
        monkeypatch.setitem(sys.modules, "mlx.core", types.ModuleType("mlx.core"))

        monkeypatch.setattr(
            "speech_stack.memory.default_memory_limit_bytes",
            MagicMock(side_effect=RuntimeError("boom")),
        )

        backend = MlxBackend(model="test-model")
        backend.load()

        assert backend._model is not None


# ---------------------------------------------------------------------------
# HF GGUF path resolution (hf:<repo_id>/<filename>)
# ---------------------------------------------------------------------------


class TestResolveGgufPath:
    """Resolver for hf:<repo_id>/<filename> specs — hf_hub_download mocked."""

    pytestmark = pytest.mark.usefixtures("execution_capability")

    _REPO = "google/gemma-4-E4B-it-qat-q4_0-gguf"
    _FILE = "gemma-4-E4B_q4_0-it.gguf"

    def _mock_hf_hub(self, monkeypatch, calls):
        """Inject a fake huggingface_hub so no real download occurs."""
        import sys
        import types

        fake = types.ModuleType("huggingface_hub")

        def fake_download(repo_id, filename):
            calls.append((repo_id, filename))
            return f"/fake/cache/{repo_id}/{filename}"

        fake.hf_hub_download = fake_download
        monkeypatch.setitem(sys.modules, "huggingface_hub", fake)

    def test_resolve_gguf_path_calls_hf_hub_download(self, monkeypatch):
        calls = []
        self._mock_hf_hub(monkeypatch, calls)

        path = resolve_gguf_path(self._REPO, self._FILE)

        assert path == f"/fake/cache/{self._REPO}/{self._FILE}"
        assert calls == [(self._REPO, self._FILE)]

    def test_hf_spec_resolved_via_factory(self, monkeypatch):
        calls = []
        self._mock_hf_hub(monkeypatch, calls)

        backend = create_backend("gguf", model=f"hf:{self._REPO}/{self._FILE}")

        assert isinstance(backend, GgufBackend)
        assert backend.model_path == f"/fake/cache/{self._REPO}/{self._FILE}"
        # repo_id keeps its own slash; only the last segment is the filename.
        assert calls == [(self._REPO, self._FILE)]

    def test_plain_path_is_not_resolved(self, monkeypatch):
        calls = []
        self._mock_hf_hub(monkeypatch, calls)

        backend = create_backend("gguf", model="/path/to/model.gguf")

        assert backend.model_path == "/path/to/model.gguf"
        assert calls == []  # a real path never triggers a download

    def test_resolve_model_spec_passthrough(self):
        assert _resolve_model_spec("/local/model.gguf") == "/local/model.gguf"

    def test_malformed_hf_spec_raises(self):
        with pytest.raises(ValueError, match="Invalid HF GGUF spec"):
            _resolve_model_spec("hf:norepoorfilename")
