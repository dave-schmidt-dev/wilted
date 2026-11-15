"""A stand-in for the local GGUF backend, as far as the worker can see it."""
from __future__ import annotations

import json
import types
from dataclasses import dataclass, field


@dataclass
class FakeLLM:
    """The previous project's GGUF backend, as far as the worker can see it.

    It loads lazily and refuses to answer until it has: that asymmetry is the
    whole TWiT 1098 regression, so the double reproduces it exactly.
    """

    answer: str = "[]"
    loaded: bool = False
    closed: bool = False
    fail_load: Exception | None = None
    fail_generate: Exception | None = None
    requests: list = field(default_factory=list)
    request_contents: list = field(default_factory=list)
    request_prompts: list = field(default_factory=list)
    measured_prompts: list = field(default_factory=list)
    prepared_prompts: list = field(default_factory=list)

    def load(self):
        if self.fail_load is not None:
            raise self.fail_load
        self.loaded = True

    def generate(self, system_prompt, user_content, *, response_format=None, prepared_prompt=None):
        if prepared_prompt is not None:
            expected = (system_prompt, user_content, json.dumps(response_format or {}, sort_keys=True))
            if prepared_prompt.request_key != expected:
                raise ValueError("prepared fake request mismatch")
            self.prepared_prompts.append(prepared_prompt)
        self.requests.append(response_format)
        self.request_contents.append(user_content)
        self.request_prompts.append(system_prompt)
        if not self.loaded:
            raise RuntimeError("Model not loaded. Call load() first.")
        if self.fail_generate is not None:
            raise self.fail_generate
        return self.answer, 1

    def measure_prompt(self, system_prompt, user_content, *, response_format=None):
        """Deterministic non-inference budget query; dense test text can overflow it."""
        if not self.loaded:
            raise RuntimeError("Model not loaded. Call load() first.")
        self.measured_prompts.append((system_prompt, user_content, response_format))
        payload = (
            system_prompt + "\n" + user_content + "\n"
            + json.dumps(response_format or {}, sort_keys=True)
        ).encode("utf-8")
        token_count = max(1, (len(payload) + 3) // 4)
        # Plain FakeLLM uses these defaults; summary doubles may override the
        # same class attributes without inheriting dataclass field defaults.
        context_size = getattr(self, "context_size", 8192)
        output_reserve = getattr(self, "output_reserve", 1024)
        if (output_reserve >= context_size
                or token_count + output_reserve > context_size):
            raise ValueError(
                f"Requested tokens ({token_count + output_reserve}) "
                f"exceed context window of {context_size}"
            )
        return types.SimpleNamespace(
            token_count=token_count,
            context_size=context_size,
            output_reserve=output_reserve,
            request_key=(system_prompt, user_content, json.dumps(response_format or {}, sort_keys=True)),
        )

    def close(self):
        self.closed = True
