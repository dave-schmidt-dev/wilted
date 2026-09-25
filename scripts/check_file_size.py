"""Enforce source and test file line limits with documented exceptions."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys


DEFAULT_MAX_LINES = 500
DEFAULT_EXCEPTIONS_PATH = ".file-size-exceptions"
CHECKED_SUFFIXES = (".swift", ".py", ".sh")


def count_lines(contents: bytes) -> int:
    """Return the number of lines in *contents* without decoding it."""
    if not contents:
        return 0
    return contents.count(b"\n") + (not contents.endswith(b"\n"))


def applies_to(path: str) -> bool:
    """Return whether *path* is a source or test path covered by this rule."""
    return ".xcodeproj/" not in path and path.endswith(CHECKED_SUFFIXES)


def parse_exceptions(contents: bytes, source: str, strict: bool) -> tuple[dict[str, tuple[int, str]], list[str]]:
    """Parse exception *contents* and return entries and format errors.

    When *strict* is false, malformed entries are ignored for comparison with
    a prior committed exceptions file.
    """
    try:
        text = contents.decode()
    except UnicodeDecodeError:
        return {}, [f"{source}: exceptions file must be UTF-8"] if strict else []

    entries: dict[str, tuple[int, str]] = {}
    errors: list[str] = []
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split(maxsplit=2)
        if len(fields) < 3 or not fields[2].strip():
            if strict:
                errors.append(f"{source}:{line_number}: exception entry needs a positive cap and reason")
            continue
        path, cap_text, reason = fields
        try:
            cap = int(cap_text)
        except ValueError:
            if strict:
                errors.append(f"{source}:{line_number}: cap must be a positive integer")
            continue
        if cap <= 0:
            if strict:
                errors.append(f"{source}:{line_number}: cap must be a positive integer")
            continue
        entries[path] = (cap, reason)
    return entries, errors


def run_git(arguments: list[str]) -> tuple[bytes | None, str | None]:
    """Run Git with *arguments*, returning stdout or a diagnostic error."""
    result = subprocess.run(["git", *arguments], capture_output=True, check=False)
    if result.returncode == 0:
        return result.stdout, None
    detail = result.stderr.decode(errors="replace").strip()
    return None, detail or f"git {' '.join(arguments)} failed"


def index_blob(path: str) -> tuple[bytes | None, str | None]:
    """Return the indexed blob for *path*, or a diagnostic when it is absent."""
    return run_git(["cat-file", "blob", f":{path}"])


def indexed_paths() -> tuple[list[str], list[str]]:
    """Return paths to check in staged mode and Git invocation errors."""
    changed, error = run_git(["diff", "--cached", "--name-only", "--", DEFAULT_EXCEPTIONS_PATH])
    if error:
        return [], [error]
    arguments = ["ls-files", "-z"] if changed else ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"]
    output, error = run_git(arguments)
    if error:
        return [], [error]
    return [os.fsdecode(path) for path in output.split(b"\0") if path], []


def all_paths() -> tuple[list[str], list[str]]:
    """Return all working-tree paths selected by Git and invocation errors."""
    output, error = run_git(["ls-files", "-z", "-co", "--exclude-standard"])
    if error:
        return [], [error]
    return [os.fsdecode(path) for path in output.split(b"\0") if path], []


def working_exceptions(path: str) -> tuple[dict[str, tuple[int, str]], list[str]]:
    """Load and validate exceptions from working-tree *path*."""
    exception_path = Path(path)
    if not exception_path.exists():
        return {}, []
    try:
        return parse_exceptions(exception_path.read_bytes(), path, True)
    except OSError as error:
        return {}, [f"{path}: {error}"]


def staged_exceptions() -> tuple[dict[str, tuple[int, str]], list[str]]:
    """Load and validate exceptions from the index, if it contains the file."""
    contents, error = index_blob(DEFAULT_EXCEPTIONS_PATH)
    if error:
        return {}, []
    return parse_exceptions(contents, DEFAULT_EXCEPTIONS_PATH, True)


def grandfathered_errors(entries: dict[str, tuple[int, str]]) -> list[str]:
    """Return errors for new or raised staged grandfathered exception caps."""
    contents, error = run_git(["cat-file", "blob", f"HEAD:{DEFAULT_EXCEPTIONS_PATH}"])
    if error:
        return []
    previous, _ = parse_exceptions(contents, f"HEAD:{DEFAULT_EXCEPTIONS_PATH}", False)
    errors: list[str] = []
    for path, (cap, reason) in entries.items():
        if reason.startswith("grandfathered") and (path not in previous or cap > previous[path][0]):
            errors.append(f"{path}: grandfathered exception cap may not be added or raised")
    return errors


def check_files(
    paths: list[str],
    exceptions: dict[str, tuple[int, str]],
    max_lines: int,
    exceptions_path: str,
    staged: bool,
) -> list[str]:
    """Check *paths* and return every line-limit violation found."""
    errors: list[str] = []
    for path in paths:
        if not applies_to(path):
            continue
        if staged:
            contents, error = index_blob(path)
            if error:
                errors.append(f"{path}: unable to read staged blob: {error}")
                continue
        else:
            file_path = Path(path)
            if not file_path.is_file():
                continue
            try:
                contents = file_path.read_bytes()
            except OSError as error:
                errors.append(f"{path}: {error}")
                continue
        line_count = count_lines(contents)
        exception = exceptions.get(path)
        if line_count <= max_lines:
            if exception is not None:
                print(
                    f"{path}: {line_count} lines is at or under {max_lines}; "
                    f"remove its exception from {exceptions_path}"
                )
        elif exception is None or line_count > exception[0]:
            errors.append(
                f"{path}: {line_count} lines exceeds {max_lines}; split it or "
                f"add a justified entry to {exceptions_path}"
            )
    return errors


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    """Parse command-line *arguments* for the file-size checker."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-lines", type=int, default=DEFAULT_MAX_LINES)
    parser.add_argument("--exceptions", default=DEFAULT_EXCEPTIONS_PATH)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--staged", action="store_true")
    modes.add_argument("--all", action="store_true")
    parser.add_argument("files", metavar="FILE", nargs="*")
    options = parser.parse_args(arguments)
    if (options.staged or options.all) == bool(options.files):
        parser.error("provide exactly one of --staged, --all, or FILE arguments")
    return options


def main(arguments: list[str] | None = None) -> int:
    """Check the selected files from *arguments* and return an exit status."""
    options = parse_arguments(sys.argv[1:] if arguments is None else arguments)
    errors: list[str] = []
    if options.max_lines <= 0:
        errors.append("--max-lines must be a positive integer")

    if options.staged:
        paths, path_errors = indexed_paths()
        exceptions, exception_errors = staged_exceptions()
        errors.extend(path_errors)
        errors.extend(exception_errors)
        errors.extend(grandfathered_errors(exceptions))
        errors.extend(check_files(paths, exceptions, options.max_lines, DEFAULT_EXCEPTIONS_PATH, True))
    else:
        paths, path_errors = all_paths() if options.all else (options.files, [])
        exceptions, exception_errors = working_exceptions(options.exceptions)
        errors.extend(path_errors)
        errors.extend(exception_errors)
        errors.extend(check_files(paths, exceptions, options.max_lines, options.exceptions, False))

    for error in errors:
        print(error, file=sys.stderr)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
