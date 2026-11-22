#!/usr/bin/env python3
"""Resolve a path using realpath semantics, including missing path suffixes."""

from __future__ import annotations

import os
import sys
from os import PathLike


def canonical_path(path: str | PathLike[str]) -> str:
    """Return the canonical spelling of a path without requiring its leaf."""
    return os.path.realpath(os.fspath(path))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: canonical_path.py PATH", file=sys.stderr)
        return 2
    print(canonical_path(sys.argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
