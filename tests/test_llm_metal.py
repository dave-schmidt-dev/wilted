"""Opt-in smoke test proving the installed llama-cpp-python is the Metal build.

This test is a runtime smoke check for the core ``llama-cpp-python==0.3.34``
dependency's compiled GPU support. Packaging policy requests a source build
with Metal enabled; this test verifies the installed artifact itself.

It is opt-in (skipped by default) because the default test environment may not
have llama-cpp-python installed or be Apple Silicon macOS.
"""

from __future__ import annotations

import importlib.util
import platform
import sys

import pytest

pytestmark = pytest.mark.skipif(
    importlib.util.find_spec("llama_cpp") is None or not (sys.platform == "darwin" and platform.machine() == "arm64"),
    reason="requires core llama-cpp-python on Apple Silicon macOS",
)


def test_llama_cpp_metal_offload_compiled_in():
    """Assert the installed llama_cpp build has GPU/Metal offload compiled in.

    ``llama_supports_gpu_offload()`` reflects how the installed library was
    compiled. Calling it does not load a model or touch the network.
    """
    import llama_cpp

    assert hasattr(llama_cpp, "llama_supports_gpu_offload"), (
        "llama_cpp is missing llama_supports_gpu_offload — re-check the installed "
        "version's API surface (dir(llama_cpp)) if this fires after an upgrade"
    )
    assert llama_cpp.llama_supports_gpu_offload() is True, (
        "llama_cpp reports no GPU offload support — rebuild llama-cpp-python "
        "with Metal enabled and verify the installed artifact"
    )
