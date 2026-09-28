"""Worker module split from wilted_pipeline.py."""
from __future__ import annotations
import contextlib
import difflib
import errno
import fcntl
import html
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
from dataclasses import dataclass
from hashlib import sha256
from pathlib import Path

def _experimental_id_response_format(field: str, permitted_ids: tuple[int, ...]) -> dict:
    return {
        "type": "json_object",
        "schema": {
            "type": "object",
            "properties": {field: {"type": "array", "items": {"type": "integer", "enum": list(permitted_ids)}}},
            "required": [field],
            "additionalProperties": False,
        },
    }

def _commercial_preservation_response_format(labelled_ids: tuple[int, ...]) -> dict:
    """Constrain preservation to one label for every nearby passage."""
    return {
        "type": "json_object",
        "schema": {
            "type": "object",
            "properties": {
                "labels": {
                    "type": "object",
                    "properties": {
                        str(segment_id): {
                            "type": "string",
                            "enum": ["commercial", "programme", "mixed"],
                        }
                        for segment_id in labelled_ids
                    },
                    "required": [str(segment_id) for segment_id in labelled_ids],
                    "additionalProperties": False,
                },
            },
            "required": ["labels"],
            "additionalProperties": False,
        },
    }

def _commercial_preservation_labels(
    response: str, labelled_ids: tuple[int, ...]
) -> dict[str, str]:
    """Return complete per-ID labels or reject an incomplete preservation review."""
    parsed = json.loads(response)
    expected_keys = {str(segment_id) for segment_id in labelled_ids}
    if (
        not isinstance(parsed, dict)
        or set(parsed) != {"labels"}
        or not isinstance(parsed["labels"], dict)
        or set(parsed["labels"]) != expected_keys
        or any(
            not isinstance(label, str)
            or label not in {"commercial", "programme", "mixed"}
            for label in parsed["labels"].values()
        )
    ):
        raise ValueError("programme preservation response has an invalid shape")
    return parsed["labels"]

def _commercial_conflict_response_format() -> dict:
    """Constrain conflicting evidence resolution to one verified classification."""
    return {
        "type": "json_object",
        "schema": {
            "type": "object",
            "properties": {
                "classification": {
                    "type": "string",
                    "enum": ["commercial", "programme", "mixed"],
                },
            },
            "required": ["classification"],
            "additionalProperties": False,
        },
    }

def _parse_commercial_conflict_response(response: str) -> str:
    """Return the resolved classification or reject an invalid model response."""
    parsed = json.loads(response)
    if (
        not isinstance(parsed, dict)
        or set(parsed) != {"classification"}
        or not isinstance(parsed["classification"], str)
        or parsed["classification"] not in {"commercial", "programme", "mixed"}
    ):
        raise ValueError("commercial conflict resolution response has an invalid shape")
    return parsed["classification"]

def _parse_experimental_ids(response: str, field: str, permitted_ids: tuple[int, ...], *, nonempty: bool) -> tuple[int, ...]:
    parsed = json.loads(response)
    if not isinstance(parsed, dict) or set(parsed) != {field} or not isinstance(parsed[field], list):
        raise ValueError(f"response must contain exactly {field}")
    values = parsed[field]
    if any(isinstance(value, bool) or not isinstance(value, int) for value in values):
        raise ValueError(f"{field} must contain integer IDs")
    positions = {segment_id: index for index, segment_id in enumerate(permitted_ids)}
    if any(value not in positions for value in values) or len(set(values)) != len(values):
        raise ValueError(f"{field} contains duplicate or out-of-range IDs")
    if values != sorted(values, key=positions.__getitem__) or (nonempty and not values):
        raise ValueError(f"{field} is empty or out of order")
    return tuple(values)
