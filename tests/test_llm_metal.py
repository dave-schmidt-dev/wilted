"""Opt-in smoke test proving the installed llama-cpp-python is the Metal build.

This test exists because the ``llm`` extra pins ``llama-cpp-python==0.3.33``
sourced from the abetlen Metal wheel index (see ``pyproject.toml``
``[tool.uv.sources]`` / ``[[tool.uv.index]]``), NOT the PyPI sdist — the sdist
builds CPU-only from source. If a resolver change, cache issue, or index
misconfiguration ever silently substitutes a CPU wheel or a from-source build,
this test is the tripwire: it fails loudly instead of only showing up later as
slow, CPU-bound inference.

It is opt-in (skipped by default) because it requires the ``llm`` extra to be
installed, which the default ``make validate`` gate does not install.
"""

from __future__ import annotations

import importlib.util
import platform
import sys

import pytest

pytestmark = pytest.mark.skipif(
    importlib.util.find_spec("llama_cpp") is None or not (sys.platform == "darwin" and platform.machine() == "arm64"),
    reason="requires the 'llm' extra (llama-cpp-python) on Apple Silicon macOS",
)


def test_llama_cpp_metal_offload_compiled_in():
    """Assert the installed llama_cpp build has GPU/Metal offload compiled in.

    ``llama_supports_gpu_offload()`` is a thin ctypes binding onto the
    underlying llama.cpp C library and reflects how that library was
    *compiled* — it returns True only when a GPU backend (Metal on Apple
    Silicon) was built in, and False for a CPU-only build such as the one
    produced by building the PyPI sdist from source. Calling it does not
    load a model or touch the network, so it proves the wheel identity
    without any of the cost or nondeterminism of running inference.
    """
    import llama_cpp

    assert hasattr(llama_cpp, "llama_supports_gpu_offload"), (
        "llama_cpp is missing llama_supports_gpu_offload — re-check the installed "
        "version's API surface (dir(llama_cpp)) if this fires after an upgrade"
    )
    assert llama_cpp.llama_supports_gpu_offload() is True, (
        "llama_cpp reports no GPU offload support — this means a CPU-only build "
        "is installed instead of the pinned Metal wheel (llama-cpp-python==0.3.33 "
        "from the llama-cpp-python-metal index)"
    )
