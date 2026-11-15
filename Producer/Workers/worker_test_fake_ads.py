"""Shared worker test doubles: a stand-in `wilted.llm` and a detection record."""
from __future__ import annotations

import sys
import types
from dataclasses import dataclass

from worker_test_support import *  # noqa: F403
from worker_test_support import install_fake_speech_stack


@dataclass
class FakeAd:
    """A removed span a test hands to the silence-trim fixtures."""

    start_s: float
    end_s: float
    label: str = "sponsor"
    confidence: float = 0.9
    kinds: tuple = ()


def install_fake_ads(llm, detections=()):
    """Stand in for `wilted.llm` so no test can load a local model.

    `create_backend` returns `llm`. `detections` is accepted so the older call
    shape keeps working; nothing reads it.
    """
    host = sys.modules.get("speech_stack.daemon.host")
    if "speech_stack.client" not in sys.modules or host is None or not host.state_dir().is_dir():
        install_fake_speech_stack()
    llm_module = types.ModuleType("wilted.llm")
    llm_module.DEFAULT_GGUF_MODEL = "/models/default.gguf"
    llm_module.create_backend = lambda kind, model: llm
    package = sys.modules.get("wilted") or types.ModuleType("wilted")
    package.llm = llm_module
    sys.modules["wilted"] = package
    sys.modules["wilted.llm"] = llm_module
    return llm_module
