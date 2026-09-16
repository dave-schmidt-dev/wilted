"""Regression coverage for the narrow Gemma 4 E4B GGUF metadata repair."""

from __future__ import annotations

import struct
from typing import TYPE_CHECKING

import pytest

from wilted.gguf_repair import (
    GGUFRepairError,
    _align_up,
    _parse_gguf,
    repair_gemma_4_12b_gguf,
    repair_gemma_4_26b_gguf,
    repair_gemma_4_e2b_gguf,
    repair_gemma_4_e4b_gguf,
)

if TYPE_CHECKING:
    from pathlib import Path


def _string(value: str) -> bytes:
    raw = value.encode("utf-8")
    return struct.pack("<Q", len(raw)) + raw


def _kv(key: str, value_type: int, value: bytes) -> bytes:
    return _string(key) + struct.pack("<I", value_type) + value


def _broken_tokens(*, bad_token: bool = False) -> list[str]:
    tokens = [f"token-{index}" for index in range(262_144)]
    tokens[715] = "//" if not bad_token else "not-slash"
    tokens[135260] = "//"
    tokens[8510] = "<?"
    tokens[140291] = "<?"
    tokens[208867] = "#"
    tokens[236865] = "#"
    return tokens


def _write_fixture(
    path: Path,
    *,
    padding: int = 10,
    bad_token: bool = False,
    wrong_duplicate: bool = False,
    model: str = "4B_dequant_qat_it_hf",
    architecture: str = "gemma4",
) -> bytes:
    tokens = _broken_tokens(bad_token=bad_token)
    if wrong_duplicate:
        tokens[100] = "unexpected-duplicate"
        tokens[101] = "unexpected-duplicate"
    token_value = struct.pack("<IQ", 8, len(tokens)) + b"".join(_string(token) for token in tokens)
    metadata = b"".join(
        (
            _kv("general.name", 8, _string(model)),
            _kv("general.architecture", 8, _string(architecture)),
            _kv("general.alignment", 4, struct.pack("<I", 32)),
            _kv("tokenizer.ggml.tokens", 9, token_value),
        )
    )
    descriptor = _string("weight") + struct.pack("<IQIQ", 1, 1, 0, 0)
    header = b"GGUF" + struct.pack("<IQQ", 3, 1, 4) + metadata + descriptor
    # An ignored string precisely controls the final pre-tensor padding.
    target_remainder = (-padding) % 32
    extra_length = (target_remainder - len(header) - 21) % 32
    metadata += _kv("x", 8, _string("x" * extra_length))
    header = b"GGUF" + struct.pack("<IQQ", 3, 1, 5) + metadata + descriptor
    header += b"\0" * ((-len(header)) % 32)
    tensors = b"TENSOR-DATA-MUST-NOT-MOVE" * 8
    path.write_bytes(header + tensors)
    return tensors


def test_repairs_copy_and_preserves_source_and_tensors(tmp_path: Path) -> None:
    source = tmp_path / "downloaded.gguf"
    destination = tmp_path / "repaired.gguf"
    tensors = _write_fixture(source)
    original = source.read_bytes()

    assert repair_gemma_4_e4b_gguf(source, destination) == destination

    assert source.read_bytes() == original
    parsed = _parse_gguf(destination)
    assert destination.read_bytes()[parsed.tensor_offset :] == tensors
    assert [slot.value for slot in parsed.tokens][135260] == "\ufeff//"
    assert [slot.value for slot in parsed.tokens][140291] == "\ufeff<?"
    assert [slot.value for slot in parsed.tokens][208867] == "\ufeff#"
    assert parsed.tensor_offset == _parse_gguf(source).tensor_offset
    assert parsed.tensor_offset == destination.stat().st_size - len(tensors)


@pytest.mark.parametrize(
    ("source_exists", "destination_exists", "same_path", "message"),
    [
        (False, False, False, "does not exist"),
        (True, True, False, "already exists"),
        (True, False, True, "must differ"),
    ],
)
def test_refuses_bad_paths(
    tmp_path: Path, source_exists: bool, destination_exists: bool, same_path: bool, message: str
) -> None:
    source = tmp_path / "source.gguf"
    destination = source if same_path else tmp_path / "destination.gguf"
    if source_exists:
        _write_fixture(source)
    if destination_exists and destination != source:
        destination.write_bytes(b"existing")

    with pytest.raises(GGUFRepairError, match=message):
        repair_gemma_4_e4b_gguf(source, destination)


def test_refuses_unexpected_tokens_and_cleans_no_temp(tmp_path: Path) -> None:
    source = tmp_path / "broken.gguf"
    destination = tmp_path / "repaired.gguf"
    _write_fixture(source, bad_token=True)

    with pytest.raises(GGUFRepairError, match="unexpected token"):
        repair_gemma_4_e4b_gguf(source, destination)

    assert not destination.exists()
    assert not list(tmp_path.glob(".repaired.gguf.*.tmp"))


@pytest.mark.parametrize(
    ("fixture_kwargs", "message"),
    [
        ({"model": "another-model"}, "expected model name"),
        ({"architecture": "another-architecture"}, "expected architecture"),
        ({"wrong_duplicate": True}, "duplicates do not match"),
    ],
)
def test_refuses_wrong_provenance_or_duplicate_map(
    tmp_path: Path, fixture_kwargs: dict[str, object], message: str
) -> None:
    source = tmp_path / "broken.gguf"
    destination = tmp_path / "repaired.gguf"
    _write_fixture(source, **fixture_kwargs)

    with pytest.raises(GGUFRepairError, match=message):
        repair_gemma_4_e4b_gguf(source, destination)

    assert not destination.exists()
    assert not list(tmp_path.glob(".repaired.gguf.*.tmp"))


def test_refuses_insufficient_padding(tmp_path: Path) -> None:
    source = tmp_path / "broken.gguf"
    _write_fixture(source, padding=1)

    with pytest.raises(GGUFRepairError, match="10 bytes of metadata padding"):
        repair_gemma_4_e4b_gguf(source, tmp_path / "repaired.gguf")


def test_reads_only_metadata_prefix_for_patch(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    from pathlib import Path

    source = tmp_path / "broken.gguf"
    destination = tmp_path / "repaired.gguf"
    _write_fixture(source)
    read_bytes = Path.read_bytes

    def reject_full_source_read(path: Path) -> bytes:
        if path == source:
            raise AssertionError("source.read_bytes() would load the full GGUF")
        return read_bytes(path)

    monkeypatch.setattr(Path, "read_bytes", reject_full_source_read)
    repair_gemma_4_e4b_gguf(source, destination)

    assert destination.exists()


def test_destination_race_preserves_sentinel(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    source = tmp_path / "broken.gguf"
    destination = tmp_path / "repaired.gguf"
    _write_fixture(source)
    from wilted import gguf_repair

    publish = gguf_repair._publish_no_clobber

    def race_publish(temporary: Path, raced_destination: Path) -> None:
        raced_destination.write_bytes(b"sentinel")
        publish(temporary, raced_destination)

    monkeypatch.setattr(gguf_repair, "_publish_no_clobber", race_publish)
    with pytest.raises(GGUFRepairError, match="destination already exists"):
        repair_gemma_4_e4b_gguf(source, destination)

    assert destination.read_bytes() == b"sentinel"
    assert not list(tmp_path.glob(".repaired.gguf.*.tmp"))


def test_verification_failure_cleans_temporary(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    source = tmp_path / "broken.gguf"
    destination = tmp_path / "repaired.gguf"
    _write_fixture(source)

    def fail_verification(_source: Path, _temporary: Path, _offset: int) -> None:
        raise GGUFRepairError("verification failed")

    monkeypatch.setattr("wilted.gguf_repair._verify_repaired", fail_verification)
    with pytest.raises(GGUFRepairError, match="verification failed"):
        repair_gemma_4_e4b_gguf(source, destination)

    assert not destination.exists()
    assert not list(tmp_path.glob(".repaired.gguf.*.tmp"))


def test_publish_failure_cleans_temporary(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    source = tmp_path / "broken.gguf"
    destination = tmp_path / "repaired.gguf"
    _write_fixture(source)

    def fail_publish(_temporary: Path, _destination: Path) -> None:
        raise OSError("publish failed")

    monkeypatch.setattr("wilted.gguf_repair._publish_no_clobber", fail_publish)
    with pytest.raises(OSError, match="publish failed"):
        repair_gemma_4_e4b_gguf(source, destination)

    assert not destination.exists()
    assert not list(tmp_path.glob(".repaired.gguf.*.tmp"))


def test_cleans_temporary_file_when_copy_fails(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    source = tmp_path / "broken.gguf"
    _write_fixture(source)

    def fail_copy(_source: Path, _temporary: Path) -> None:
        raise OSError("copy failed")

    monkeypatch.setattr("wilted.gguf_repair._copy_source", fail_copy)
    with pytest.raises(OSError, match="copy failed"):
        repair_gemma_4_e4b_gguf(source, tmp_path / "repaired.gguf")

    assert not list(tmp_path.glob(".repaired.gguf.*.tmp"))


# --- E2B repair: same defect, zero padding, tensor section re-aligned/grown ---


def _write_e2b_fixture(path: Path, **kwargs: object) -> bytes:
    kwargs.setdefault("padding", 0)
    kwargs.setdefault("model", "2B_dequant_qat_it_hf")
    return _write_fixture(path, **kwargs)  # type: ignore[arg-type]


def test_e2b_repairs_grows_file_and_preserves_tensors(tmp_path: Path) -> None:
    source = tmp_path / "downloaded.gguf"
    destination = tmp_path / "repaired.gguf"
    tensors = _write_e2b_fixture(source)
    original = source.read_bytes()
    source_parsed = _parse_gguf(source)
    assert source_parsed.tensor_offset - source_parsed.header_end == 0  # zero padding

    assert repair_gemma_4_e2b_gguf(source, destination) == destination

    # Source untouched.
    assert source.read_bytes() == original

    parsed = _parse_gguf(destination)
    values = [slot.value for slot in parsed.tokens]
    # Correct BOM assignment (ground truth): 135260/140291/208867 carry the BOM.
    assert values[135260] == "﻿//"
    assert values[140291] == "﻿<?"
    assert values[208867] == "﻿#"
    # The *other* member of each pair stays plain — guards against agy's inversion.
    assert values[715] == "//"
    assert values[8510] == "<?"
    assert values[236865] == "#"
    # Unique vocabulary (the assertion llama.cpp enforces).
    assert len(values) == len(set(values))
    # Tensor section moved to the next alignment boundary; bytes preserved.
    expected_offset = _align_up(source_parsed.header_end + 9, 32)
    assert parsed.tensor_offset == expected_offset
    assert destination.read_bytes()[parsed.tensor_offset :] == tensors
    assert destination.stat().st_size == source.stat().st_size + (expected_offset - source_parsed.tensor_offset)


def test_e2b_refuses_e4b_model_identity(tmp_path: Path) -> None:
    source = tmp_path / "broken.gguf"
    _write_e2b_fixture(source, model="4B_dequant_qat_it_hf")

    with pytest.raises(GGUFRepairError, match="expected model name"):
        repair_gemma_4_e2b_gguf(source, tmp_path / "repaired.gguf")


def test_e2b_refuses_nonzero_padding(tmp_path: Path) -> None:
    source = tmp_path / "broken.gguf"
    _write_e2b_fixture(source, padding=10)

    with pytest.raises(GGUFRepairError, match="expected 0 bytes of metadata padding"):
        repair_gemma_4_e2b_gguf(source, tmp_path / "repaired.gguf")


def test_e2b_refuses_wrong_duplicate_map(tmp_path: Path) -> None:
    source = tmp_path / "broken.gguf"
    _write_e2b_fixture(source, wrong_duplicate=True)

    with pytest.raises(GGUFRepairError, match="duplicates do not match"):
        repair_gemma_4_e2b_gguf(source, tmp_path / "repaired.gguf")


def test_e2b_refuses_existing_destination(tmp_path: Path) -> None:
    source = tmp_path / "broken.gguf"
    destination = tmp_path / "repaired.gguf"
    _write_e2b_fixture(source)
    destination.write_bytes(b"existing")

    with pytest.raises(GGUFRepairError, match="already exists"):
        repair_gemma_4_e2b_gguf(source, destination)

    assert destination.read_bytes() == b"existing"
    assert not list(tmp_path.glob(".repaired.gguf.*.tmp"))


# --- 12B / 26B: same defect, ample padding, fixed-offset (tensor never moves) ---

_FIXED_OFFSET_VARIANTS = [
    ("12B_qat_it_dequant_safetensors", 14, repair_gemma_4_12b_gguf),
    ("26B_dequant_it_hf", 19, repair_gemma_4_26b_gguf),
]


@pytest.mark.parametrize(("model", "padding", "repair"), _FIXED_OFFSET_VARIANTS)
def test_fixed_offset_variants_repair_in_place(tmp_path: Path, model: str, padding: int, repair: object) -> None:
    source = tmp_path / "downloaded.gguf"
    destination = tmp_path / "repaired.gguf"
    tensors = _write_fixture(source, padding=padding, model=model)
    original = source.read_bytes()
    source_offset = _parse_gguf(source).tensor_offset

    assert repair(source, destination) == destination  # type: ignore[operator]

    assert source.read_bytes() == original  # source untouched
    parsed = _parse_gguf(destination)
    values = [slot.value for slot in parsed.tokens]
    assert values[135260] == "﻿//"
    assert values[140291] == "﻿<?"
    assert values[208867] == "﻿#"
    assert values[715] == "//"
    assert values[8510] == "<?"
    assert values[236865] == "#"  # unchanged member of the # pair
    assert len(values) == len(set(values))  # unique vocabulary
    # Fixed-offset: tensor section and file size are unchanged.
    assert parsed.tensor_offset == source_offset
    assert destination.stat().st_size == source.stat().st_size
    assert destination.read_bytes()[parsed.tensor_offset :] == tensors


@pytest.mark.parametrize(("model", "padding", "repair"), _FIXED_OFFSET_VARIANTS)
def test_fixed_offset_variants_reject_wrong_padding(tmp_path: Path, model: str, padding: int, repair: object) -> None:
    source = tmp_path / "broken.gguf"
    _write_fixture(source, padding=padding + 1, model=model)

    with pytest.raises(GGUFRepairError, match=f"expected {padding} bytes of metadata padding"):
        repair(source, tmp_path / "repaired.gguf")  # type: ignore[operator]


@pytest.mark.parametrize(("model", "padding", "repair"), _FIXED_OFFSET_VARIANTS)
def test_fixed_offset_variants_reject_wrong_model(tmp_path: Path, model: str, padding: int, repair: object) -> None:
    source = tmp_path / "broken.gguf"
    _write_fixture(source, padding=padding, model="4B_dequant_qat_it_hf")

    with pytest.raises(GGUFRepairError, match="expected model name"):
        repair(source, tmp_path / "repaired.gguf")  # type: ignore[operator]
