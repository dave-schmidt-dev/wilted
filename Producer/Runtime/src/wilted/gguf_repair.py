"""Repair the verified July 2026 Gemma 4 QAT GGUF tokenizer defect.

Two separately validated repairs live here, one per proven defect:

* ``repair_gemma_4_e4b_gguf`` — the E4B snapshot, which has ten bytes of
  metadata padding, so the three BOM prefixes are absorbed in place and the
  tensor section never moves.
* ``repair_gemma_4_e2b_gguf`` — the E2B snapshot, which carries the identical
  tokenizer defect but has *zero* metadata padding, so the tensor section is
  re-aligned to the next boundary and the file grows by that alignment gap.

Each repair accepts only its known model/architecture metadata, token count,
duplicate-token map, and padding layout.  Both create a separate repaired file
and never change the downloaded source.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import shutil
import struct
import subprocess
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

_MAGIC = b"GGUF"
_VERSION = 3
_ALIGNMENT = 32
_TOKEN_KEY = "tokenizer.ggml.tokens"
_MODEL_KEY = "general.name"
_ARCHITECTURE_KEY = "general.architecture"
_EXPECTED_MODEL_NAME = "4B_dequant_qat_it_hf"
_EXPECTED_ARCHITECTURE = "gemma4"
_EXPECTED_TOKEN_COUNT = 262_144
_BROKEN_TOKENS = {715: "//", 8510: "<?", 208867: "#"}
_REPAIRED_TOKENS = {
    135260: "\ufeff//",
    140291: "\ufeff<?",
    208867: "\ufeff#",
}
# The three duplicate pairs whose *other* member must stay plain after a repair.
# Ground truth (the pre-defect snapshots) puts the BOM on 135260/140291/208867
# and leaves 715/8510/236865 as the bare strings.  Guarding these ids rejects an
# inverted repair that BOM-prefixes the wrong member of the ``#`` pair.
_UNCHANGED_PLAIN_TOKENS = {715: "//", 8510: "<?", 236865: "#"}
# All four July 2026 Gemma 4 QAT GGUFs carry the identical token defect (the
# same three duplicate strings at the same ids) but differ in model name and in
# how much metadata padding is available to absorb the nine BOM bytes.  Each
# variant is validated against its exact observed name and padding; nothing is
# assumed to carry over between models.  When padding >= 9 the tensor section
# stays put (fixed-offset); the zero-padding E2B grows and re-aligns instead.
_E4B_EXPECTED_MODEL_NAME = _EXPECTED_MODEL_NAME
_E4B_EXPECTED_PADDING = 10
_E2B_EXPECTED_MODEL_NAME = "2B_dequant_qat_it_hf"
_E2B_EXPECTED_PADDING = 0
_12B_EXPECTED_MODEL_NAME = "12B_qat_it_dequant_safetensors"
_12B_EXPECTED_PADDING = 14
_26B_EXPECTED_MODEL_NAME = "26B_dequant_it_hf"
_26B_EXPECTED_PADDING = 19
_SCALAR_SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}


class GGUFRepairError(ValueError):
    """Raised when a file is not precisely the affected Gemma GGUF."""


@dataclass(frozen=True)
class _StringSlot:
    length_offset: int
    value_offset: int
    value_length: int
    value: str


@dataclass(frozen=True)
class _ParsedGGUF:
    tokens: tuple[_StringSlot, ...]
    model_name: str
    architecture: str
    header_end: int
    tensor_offset: int


def _read_exact(handle: object, size: int) -> bytes:
    data = handle.read(size)  # type: ignore[attr-defined]
    if len(data) != size:
        raise GGUFRepairError("truncated GGUF metadata")
    return data


def _u32(handle: object) -> int:
    return struct.unpack("<I", _read_exact(handle, 4))[0]


def _u64(handle: object) -> int:
    return struct.unpack("<Q", _read_exact(handle, 8))[0]


def _read_string(handle: object) -> _StringSlot:
    length_offset = handle.tell()  # type: ignore[attr-defined]
    length = _u64(handle)
    value_offset = handle.tell()  # type: ignore[attr-defined]
    try:
        value = _read_exact(handle, length).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise GGUFRepairError("GGUF metadata contains invalid UTF-8") from exc
    return _StringSlot(length_offset, value_offset, length, value)


def _skip_value(handle: object, value_type: int) -> None:
    if value_type == 8:
        _read_string(handle)
        return
    if value_type == 9:
        element_type = _u32(handle)
        count = _u64(handle)
        for _ in range(count):
            _skip_value(handle, element_type)
        return
    try:
        size = _SCALAR_SIZES[value_type]
    except KeyError as exc:
        raise GGUFRepairError(f"unsupported GGUF metadata type {value_type}") from exc
    _read_exact(handle, size)


def _parse_gguf(path: Path) -> _ParsedGGUF:
    with path.open("rb") as handle:
        if _read_exact(handle, 4) != _MAGIC:
            raise GGUFRepairError("not a GGUF file")
        if _u32(handle) != _VERSION:
            raise GGUFRepairError("expected GGUF version 3")
        tensor_count = _u64(handle)
        metadata_count = _u64(handle)
        tokens: tuple[_StringSlot, ...] | None = None
        model_name: str | None = None
        architecture: str | None = None
        alignment = _ALIGNMENT
        for _ in range(metadata_count):
            key = _read_string(handle).value
            value_type = _u32(handle)
            if key == _TOKEN_KEY:
                if value_type != 9 or _u32(handle) != 8:
                    raise GGUFRepairError("tokenizer.ggml.tokens is not a string array")
                tokens = tuple(_read_string(handle) for _ in range(_u64(handle)))
            elif key == _MODEL_KEY:
                if value_type != 8:
                    raise GGUFRepairError("general.name is not a string")
                model_name = _read_string(handle).value
            elif key == _ARCHITECTURE_KEY:
                if value_type != 8:
                    raise GGUFRepairError("general.architecture is not a string")
                architecture = _read_string(handle).value
            elif key == "general.alignment":
                if value_type != 4:
                    raise GGUFRepairError("general.alignment is not uint32")
                alignment = _u32(handle)
            else:
                _skip_value(handle, value_type)
        for _ in range(tensor_count):
            _read_string(handle)  # tensor name
            dimensions = _u32(handle)
            _read_exact(handle, dimensions * 8)  # dimensions
            _u32(handle)  # ggml tensor type
            _u64(handle)  # offset relative to the aligned tensor section
        header_end = handle.tell()

    if alignment != _ALIGNMENT:
        raise GGUFRepairError(f"expected {_ALIGNMENT}-byte tensor alignment")
    tensor_offset = (header_end + alignment - 1) // alignment * alignment
    if tensor_offset > path.stat().st_size:
        raise GGUFRepairError("GGUF has no tensor data after metadata")
    if tokens is None or model_name is None or architecture is None:
        raise GGUFRepairError("missing Gemma tokenizer or model metadata")
    return _ParsedGGUF(tokens, model_name, architecture, header_end, tensor_offset)


def _validate_broken(
    path: Path,
    *,
    expected_model_name: str = _E4B_EXPECTED_MODEL_NAME,
    expected_padding: int = _E4B_EXPECTED_PADDING,
) -> _ParsedGGUF:
    parsed = _parse_gguf(path)
    if parsed.model_name != expected_model_name:
        raise GGUFRepairError(f"expected model name {expected_model_name!r}, got {parsed.model_name!r}")
    if parsed.architecture != _EXPECTED_ARCHITECTURE:
        raise GGUFRepairError(f"expected architecture {_EXPECTED_ARCHITECTURE!r}, got {parsed.architecture!r}")
    if len(parsed.tokens) != _EXPECTED_TOKEN_COUNT:
        raise GGUFRepairError(f"expected {_EXPECTED_TOKEN_COUNT} tokenizer entries")
    actual = tuple(slot.value for slot in parsed.tokens)
    for token_id, token in _BROKEN_TOKENS.items():
        if actual[token_id] != token:
            raise GGUFRepairError(f"unexpected token at id {token_id}")
    duplicates = {token: ids for token, ids in _duplicate_ids(actual).items()}
    expected_duplicates = {
        "//": (715, 135260),
        "<?": (8510, 140291),
        "#": (208867, 236865),
    }
    if duplicates != expected_duplicates:
        raise GGUFRepairError("tokenizer duplicates do not match the known July 2026 defect")
    padding = parsed.tensor_offset - parsed.header_end
    if padding != expected_padding:
        raise GGUFRepairError(f"expected {expected_padding} bytes of metadata padding, found {padding}")
    with path.open("rb") as handle:
        handle.seek(parsed.header_end)
        if _read_exact(handle, padding) != b"\0" * padding:
            raise GGUFRepairError("metadata padding is not all zeroes")
    return parsed


def _duplicate_ids(tokens: tuple[str, ...]) -> dict[str, tuple[int, ...]]:
    counts = Counter(tokens)
    return {
        token: tuple(index for index, value in enumerate(tokens) if value == token)
        for token, count in counts.items()
        if count > 1
    }


def _repair_growth(parsed: _ParsedGGUF) -> int:
    """Total extra bytes the three BOM prefixes add to the metadata."""
    return sum(
        len(repaired.encode("utf-8")) - parsed.tokens[token_id].value_length
        for token_id, repaired in _REPAIRED_TOKENS.items()
    )


def _patched_header(source: Path, parsed: _ParsedGGUF) -> bytes:
    """Rebuild a fixed-offset header: BOM the tokens and shrink the padding.

    The BOM bytes are absorbed by consuming ``growth`` of the trailing padding
    NULs, so the first tensor stays at exactly the same byte offset.  Requires
    ``padding >= growth`` (all variants except the zero-padding E2B).
    """
    growth = _repair_growth(parsed)
    remaining = parsed.tensor_offset - parsed.header_end - growth
    if remaining < 0:
        raise GGUFRepairError("insufficient metadata padding for a fixed-offset repair")
    with source.open("rb") as handle:
        header = _read_exact(handle, parsed.tensor_offset)
    pieces: list[bytes] = []
    cursor = 0
    for token_id, repaired in sorted(_REPAIRED_TOKENS.items(), key=lambda item: parsed.tokens[item[0]].length_offset):
        slot = parsed.tokens[token_id]
        encoded = repaired.encode("utf-8")
        pieces.extend((header[cursor : slot.length_offset], struct.pack("<Q", len(encoded)), encoded))
        cursor = slot.value_offset + slot.value_length
    pieces.append(header[cursor : parsed.header_end + remaining])
    rebuilt = b"".join(pieces)
    if len(rebuilt) != parsed.tensor_offset:
        raise GGUFRepairError("repair does not fit the verified metadata padding")
    return rebuilt


def _copy_source(source: Path, temporary: Path) -> None:
    if platform.system() == "Darwin":
        result = subprocess.run(["cp", "-c", str(source), str(temporary)], check=False, capture_output=True)
        if result.returncode == 0:
            return
    shutil.copyfile(source, temporary)


def _hash_from(path: Path, offset: int) -> bytes:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        handle.seek(offset)
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.digest()


def _verify_repaired(source: Path, destination: Path, source_tensor_offset: int) -> None:
    parsed = _parse_gguf(destination)
    repaired_tokens = tuple(slot.value for slot in parsed.tokens)
    if len(repaired_tokens) != _EXPECTED_TOKEN_COUNT or _duplicate_ids(repaired_tokens):
        raise GGUFRepairError("repaired tokenizer is not unique")
    for token_id, expected in _REPAIRED_TOKENS.items():
        if repaired_tokens[token_id] != expected:
            raise GGUFRepairError(f"repair missing at token id {token_id}")
    for token_id, expected in _UNCHANGED_PLAIN_TOKENS.items():
        if repaired_tokens[token_id] != expected:
            raise GGUFRepairError(f"repair disturbed the plain token at id {token_id}")
    if parsed.tensor_offset != source_tensor_offset or destination.stat().st_size != source.stat().st_size:
        raise GGUFRepairError("repair changed tensor offset or file size")
    if _hash_from(source, source_tensor_offset) != _hash_from(destination, source_tensor_offset):
        raise GGUFRepairError("repair changed tensor data")


def _publish_no_clobber(temporary: Path, destination: Path) -> None:
    """Atomically publish a same-directory temporary file without replacement."""
    try:
        os.link(temporary, destination)
    except FileExistsError as exc:
        raise GGUFRepairError(f"destination already exists: {destination}") from exc


def _resolve_repair_paths(source: Path | str, destination: Path | str) -> tuple[Path, Path]:
    source_path = Path(source).expanduser().resolve()
    destination_path = Path(destination).expanduser().resolve(strict=False)
    if source_path == destination_path:
        raise GGUFRepairError("source and destination must differ")
    if not source_path.is_file():
        raise GGUFRepairError(f"source GGUF does not exist: {source_path}")
    if destination_path.exists():
        raise GGUFRepairError(f"destination already exists: {destination_path}")
    if not destination_path.parent.is_dir():
        raise GGUFRepairError(f"destination directory does not exist: {destination_path.parent}")
    return source_path, destination_path


def _repair_fixed_offset(
    source: Path | str, destination: Path | str, *, expected_model_name: str, expected_padding: int
) -> Path:
    """Repair a variant whose padding (>=9) absorbs the BOMs in place.

    The source is cloned and only its metadata header is overwritten, so the
    tensor section never moves and the file size is unchanged.
    """
    source_path, destination_path = _resolve_repair_paths(source, destination)
    parsed = _validate_broken(source_path, expected_model_name=expected_model_name, expected_padding=expected_padding)
    repaired_header = _patched_header(source_path, parsed)
    temporary: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{destination_path.name}.", suffix=".tmp", dir=destination_path.parent
        )
        os.close(descriptor)
        temporary = Path(temporary_name)
        _copy_source(source_path, temporary)
        with temporary.open("r+b") as handle:
            handle.write(repaired_header)
            handle.flush()
            os.fsync(handle.fileno())
        _verify_repaired(source_path, temporary, parsed.tensor_offset)
        _publish_no_clobber(temporary, destination_path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return destination_path


def repair_gemma_4_e4b_gguf(source: Path | str, destination: Path | str) -> Path:
    """Create a repaired Gemma 4 E4B GGUF (10-byte padding) without changing its source."""
    return _repair_fixed_offset(
        source, destination, expected_model_name=_E4B_EXPECTED_MODEL_NAME, expected_padding=_E4B_EXPECTED_PADDING
    )


def repair_gemma_4_12b_gguf(source: Path | str, destination: Path | str) -> Path:
    """Create a repaired Gemma 4 12B GGUF (14-byte padding) without changing its source."""
    return _repair_fixed_offset(
        source, destination, expected_model_name=_12B_EXPECTED_MODEL_NAME, expected_padding=_12B_EXPECTED_PADDING
    )


def repair_gemma_4_26b_gguf(source: Path | str, destination: Path | str) -> Path:
    """Create a repaired Gemma 4 26B-A4B GGUF (19-byte padding) without changing its source."""
    return _repair_fixed_offset(
        source, destination, expected_model_name=_26B_EXPECTED_MODEL_NAME, expected_padding=_26B_EXPECTED_PADDING
    )


def _align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def _rebuilt_metadata(source: Path, parsed: _ParsedGGUF) -> bytes:
    """Return metadata bytes ``[0:header_end]`` with the three tokens BOM-prefixed.

    Unlike the E4B fixed-offset patch this consumes no trailing padding: the
    metadata grows by the BOM bytes and the caller re-aligns the tensor section.
    """
    with source.open("rb") as handle:
        header = _read_exact(handle, parsed.header_end)
    pieces: list[bytes] = []
    cursor = 0
    growth = 0
    for token_id, repaired in sorted(_REPAIRED_TOKENS.items(), key=lambda item: parsed.tokens[item[0]].length_offset):
        slot = parsed.tokens[token_id]
        encoded = repaired.encode("utf-8")
        pieces.extend((header[cursor : slot.length_offset], struct.pack("<Q", len(encoded)), encoded))
        cursor = slot.value_offset + slot.value_length
        growth += len(encoded) - slot.value_length
    pieces.append(header[cursor : parsed.header_end])
    rebuilt = b"".join(pieces)
    if len(rebuilt) != parsed.header_end + growth:
        raise GGUFRepairError("rebuilt metadata length is inconsistent")
    return rebuilt


def _verify_repaired_grown(source: Path, destination: Path, source_tensor_offset: int, new_tensor_offset: int) -> None:
    parsed = _parse_gguf(destination)
    if parsed.model_name != _E2B_EXPECTED_MODEL_NAME or parsed.architecture != _EXPECTED_ARCHITECTURE:
        raise GGUFRepairError("repair changed model identity")
    repaired_tokens = tuple(slot.value for slot in parsed.tokens)
    if len(repaired_tokens) != _EXPECTED_TOKEN_COUNT or _duplicate_ids(repaired_tokens):
        raise GGUFRepairError("repaired tokenizer is not unique")
    for token_id, expected in _REPAIRED_TOKENS.items():
        if repaired_tokens[token_id] != expected:
            raise GGUFRepairError(f"repair missing at token id {token_id}")
    for token_id, expected in _UNCHANGED_PLAIN_TOKENS.items():
        if repaired_tokens[token_id] != expected:
            raise GGUFRepairError(f"repair disturbed the plain token at id {token_id}")
    if parsed.tensor_offset != new_tensor_offset:
        raise GGUFRepairError("unexpected repaired tensor offset")
    expected_size = source.stat().st_size + (new_tensor_offset - source_tensor_offset)
    if destination.stat().st_size != expected_size:
        raise GGUFRepairError("repair changed file size unexpectedly")
    if _hash_from(source, source_tensor_offset) != _hash_from(destination, new_tensor_offset):
        raise GGUFRepairError("repair changed tensor data")


def repair_gemma_4_e2b_gguf(source: Path | str, destination: Path | str) -> Path:
    """Create a repaired Gemma 4 E2B GGUF without changing its source file.

    The E2B snapshot carries the same tokenizer defect as E4B but has zero
    metadata padding, so the three BOM prefixes cannot be absorbed in place.
    The tensor section is re-aligned to the next ``_ALIGNMENT``-byte boundary and
    the file grows by that gap; GGUF tensor offsets are relative to the tensor
    section start, so the copied tensor bytes stay valid.  The destination must
    not exist and is atomically published after integrity checks pass.
    """
    source_path, destination_path = _resolve_repair_paths(source, destination)
    parsed = _validate_broken(
        source_path,
        expected_model_name=_E2B_EXPECTED_MODEL_NAME,
        expected_padding=_E2B_EXPECTED_PADDING,
    )
    metadata = _rebuilt_metadata(source_path, parsed)
    new_tensor_offset = _align_up(len(metadata), _ALIGNMENT)
    temporary: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{destination_path.name}.", suffix=".tmp", dir=destination_path.parent
        )
        os.close(descriptor)
        temporary = Path(temporary_name)
        with temporary.open("wb") as out, source_path.open("rb") as src:
            out.write(metadata)
            out.write(b"\0" * (new_tensor_offset - len(metadata)))
            src.seek(parsed.tensor_offset)
            while chunk := src.read(1024 * 1024):
                out.write(chunk)
            out.flush()
            os.fsync(out.fileno())
        _verify_repaired_grown(source_path, temporary, parsed.tensor_offset, new_tensor_offset)
        _publish_no_clobber(temporary, destination_path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return destination_path


def main(argv: list[str] | None = None) -> int:
    """Run the repair utility as ``python -m wilted.gguf_repair``."""
    parser = argparse.ArgumentParser(description="Repair an affected Gemma 4 GGUF into a new file.")
    parser.add_argument("source", type=Path, help="downloaded affected GGUF (left untouched)")
    parser.add_argument("destination", type=Path, help="new repaired GGUF path (must not exist)")
    parser.add_argument(
        "--variant",
        choices=("e4b", "e2b", "12b", "26b"),
        default="e4b",
        help="which proven Gemma 4 defect to repair (default: e4b)",
    )
    args = parser.parse_args(argv)
    repairs = {
        "e4b": repair_gemma_4_e4b_gguf,
        "e2b": repair_gemma_4_e2b_gguf,
        "12b": repair_gemma_4_12b_gguf,
        "26b": repair_gemma_4_26b_gguf,
    }
    repair = repairs[args.variant]
    try:
        repaired = repair(args.source, args.destination)
    except GGUFRepairError as exc:
        parser.error(str(exc))
    print(repaired)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
