"""Packaging policy checks for the core llama.cpp dependency."""

from __future__ import annotations

import tomllib
from pathlib import Path

PYPROJECT = Path(__file__).parents[1] / "pyproject.toml"
LOCKFILE = PYPROJECT.with_name("uv.lock")

SPEECH_CRITICAL_PACKAGES = {
    "mlx",
    "mlx-metal",
    "parakeet-mlx",
    "mlx-audio",
    "mlx-lm",
    "mlx-vlm",
    "numpy",
}


def _project() -> dict:
    with PYPROJECT.open("rb") as handle:
        return tomllib.load(handle)


def test_llama_cpp_is_exact_core_dependency_without_llm_extra():
    project = _project()
    assert "llama-cpp-python==0.3.34" in project["project"]["dependencies"]
    assert "llm" not in project["project"].get("optional-dependencies", {})
    assert "mlx-vlm" in project["project"]["optional-dependencies"]["vlm"]


def test_llama_cpp_uses_source_build_metal_policy():
    project = _project()
    uv = project["tool"]["uv"]
    assert "llama-cpp-python" in uv["no-binary-package"]
    assert uv["extra-build-variables"] == {
        "llama-cpp-python": {"CMAKE_ARGS": "-DGGML_METAL=on"}
    }
    assert "llama-cpp-python" not in project["tool"].get("uv", {}).get("sources", {})
    assert all(
        index.get("name") != "llama-cpp-python-metal"
        for index in project["tool"].get("uv", {}).get("index", [])
    )


def test_speech_stack_authority_pins_match_locked_versions():
    project = _project()
    constraints = {
        name: version
        for name, version in (
            dependency.split("==", maxsplit=1)
            for dependency in project["tool"]["uv"]["constraint-dependencies"]
        )
        if name in SPEECH_CRITICAL_PACKAGES
    }
    local_lock = {
        package["name"]: package["version"]
        for package in tomllib.loads(LOCKFILE.read_text())["package"]
    }
    authority_root = (
        PYPROJECT.parent / project["tool"]["uv"]["sources"]["speech-stack"]["path"]
    ).resolve(strict=True)
    authority_lock = {
        package["name"]: package["version"]
        for package in tomllib.loads((authority_root / "uv.lock").read_text())["package"]
        if package["name"] in SPEECH_CRITICAL_PACKAGES
    }

    assert set(constraints) == SPEECH_CRITICAL_PACKAGES
    assert authority_lock.keys() == SPEECH_CRITICAL_PACKAGES
    assert constraints == authority_lock
    assert {name: local_lock.get(name) for name in SPEECH_CRITICAL_PACKAGES} == authority_lock
