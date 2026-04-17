"""Tests for Phase 2 — LLM backend interface (llm.py)."""

from __future__ import annotations

import pytest

from wilted.llm import (
    GgufBackend,
    LLMBackend,
    MlxBackend,
    create_backend,
    parse_json_response,
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
    def test_create_mlx(self):
        backend = create_backend("mlx", model="test-model")
        assert isinstance(backend, MlxBackend)
        assert backend.model_name == "test-model"

    def test_create_gguf(self):
        backend = create_backend("gguf", model="/path/to/model.gguf")
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
        )
        assert backend.n_gpu_layers == 0
        assert backend.n_ctx == 8192


# ---------------------------------------------------------------------------
# Protocol conformance
# ---------------------------------------------------------------------------


class TestProtocolConformance:
    def test_mlx_satisfies_protocol(self):
        assert isinstance(MlxBackend(model="m"), LLMBackend)

    def test_gguf_satisfies_protocol(self):
        assert isinstance(GgufBackend(model="m"), LLMBackend)


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


# ---------------------------------------------------------------------------
# Mock-based integration test
# ---------------------------------------------------------------------------


class TestMlxBackendMocked:
    """Test MlxBackend with mocked mlx_vlm imports."""

    def test_load_generate_close_cycle(self, monkeypatch):
        """Full lifecycle with mocked model."""
        import sys
        import types

        # Create mock mlx_vlm module
        mock_mlx_vlm = types.ModuleType("mlx_vlm")

        class MockProcessor:
            def apply_chat_template(self, messages, **kwargs):
                return "formatted prompt"

        mock_model = object()
        mock_processor = MockProcessor()

        mock_mlx_vlm.load = lambda model_name: (mock_model, mock_processor)
        mock_mlx_vlm.generate = lambda model, proc, **kwargs: (
            '{"playlist": "Work", "relevance_score": 0.9, "summary": "Test."}'
        )

        monkeypatch.setitem(sys.modules, "mlx_vlm", mock_mlx_vlm)

        # Create mock mlx.core module for close()
        mock_mlx = types.ModuleType("mlx")
        mock_mlx_core = types.ModuleType("mlx.core")

        class MockMetal:
            @staticmethod
            def clear_cache():
                pass

        mock_mlx_core.metal = MockMetal()
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
