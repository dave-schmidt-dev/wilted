#!/usr/bin/env python3
"""Report worker test files that contributed no tests to a verbose unittest run.

`unittest discover` imports every `test_*.py` file it finds, but a file that
defines no test methods (a class that stopped deriving from `TestCase`, a
method whose name stopped starting with `test_`) still leaves the run reporting
OK. Reading the captured verbose output and requiring every file to appear in
it catches that omission without a hand-maintained count of test files.

The CLI reads one test file path per line from stdin and takes the path of the
captured verbose output as its argument. It exits nonzero and names each
missing module on stderr.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# A test with a docstring puts its identifier alone on the line, the docstring
# and result on the next.
_VERBOSE_TEST_LINE = re.compile(r"^[^\s(]+ \((?P<identifier>[^)]+)\)(?: \.\.\.|$)")


def _module_name(test_file: str) -> str:
    """The module name `unittest discover` uses for a top-level test file."""
    return Path(test_file).stem


def _contributed_modules(verbose_output: str) -> set[str]:
    """Module names named by `test (module.Class.test) ...` verbose lines."""
    modules: set[str] = set()
    for line in verbose_output.splitlines():
        match = _VERBOSE_TEST_LINE.match(line)
        if match is None:
            continue
        modules.add(match.group("identifier").rsplit(".", 2)[0])
    return modules


def undiscovered_modules(test_files: list[str], verbose_output: str) -> list[str]:
    """Return the module names of test files that contributed zero tests.

    A file contributed tests when the verbose run named its module in a test
    identifier such as `test_name (test_ad_kind.KindTests.test_name)`. The
    module part is compared exactly, so `test_ad` is not credited with the
    tests of `test_ad_kind`.
    """
    contributed = _contributed_modules(verbose_output)
    return [module for path in test_files if (module := _module_name(path)) not in contributed]


def _test_files_from_stdin() -> list[str]:
    return [line.strip() for line in sys.stdin if line.strip()]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Report worker test files that contributed no tests to a verbose run."
    )
    parser.add_argument("verbose_output", type=Path, help="captured verbose unittest output")
    parser.add_argument(
        "test_files",
        nargs="*",
        type=Path,
        help="test files to check; read one per line from stdin when omitted",
    )
    args = parser.parse_args(argv)
    test_files = [str(path) for path in args.test_files] if args.test_files else _test_files_from_stdin()
    verbose_output = args.verbose_output.read_text(encoding="utf-8")
    missing = undiscovered_modules(test_files, verbose_output)
    for module in missing:
        print(f"pipeline worker test module contributed no tests: {module}", file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
