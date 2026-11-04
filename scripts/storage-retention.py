#!/usr/bin/env python3
"""Run bounded Wilted storage retention; report only unless --apply is given."""
from __future__ import annotations

import argparse
import fcntl
import json
import logging
from logging.handlers import RotatingFileHandler
import math
import os
from pathlib import Path
import signal
import stat
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from retention.backups import plan as backup_plan
from retention.caches import BUDGET_BYTES, evict
from retention.bundles import restore_snapshot
from retention.core import restore_archive
from retention.evidence import compact

BUDGET_SECONDS = 300.0
MAX_BUDGET_SECONDS = 300.0
MAX_RESTORE_BUDGET_SECONDS = 24 * 60 * 60
DUE_INTERVAL_SECONDS = 7 * 86400
LOG_BYTES = 2 * 1024 * 1024
LOG_BACKUPS = 4


class DeadlineExceeded(TimeoutError):
    """The run exceeded its configured wall-clock budget."""


def _timeout_handler(_signum: int, _frame: object) -> None:
    raise DeadlineExceeded("retention wall-clock budget exceeded")


def _atomic_json(path: Path, value: dict[str, object]) -> None:
    """Write JSON atomically and sync both the file and containing directory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex + ".partial")
    descriptor = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(str(temporary), str(path))
        directory = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def _logs_root(repo: Path) -> Path:
    """Create or validate the repository-local log root without following links."""
    log_dir = repo / ".logs"
    try:
        log_dir.mkdir(mode=0o700)
    except FileExistsError:
        pass
    info = log_dir.lstat()
    if (stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode)
            or info.st_dev != repo.stat().st_dev or log_dir.resolve(strict=True) != log_dir):
        raise OSError("unsafe retention log directory")
    return log_dir


def _configure_logging(repo: Path) -> logging.Logger:
    log_dir = _logs_root(repo)
    log_path = log_dir / "storage-retention.log"
    for candidate in (log_path,) + tuple(log_dir / (log_path.name + "." + str(i)) for i in range(1, LOG_BACKUPS + 1)):
        if candidate.is_symlink():
            raise OSError("unsafe retention log file")
        if candidate.exists():
            info = candidate.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_dev != log_dir.stat().st_dev:
                raise OSError("unsafe retention log file")
    logger = logging.getLogger("wilted.storage_retention")
    logger.setLevel(logging.INFO)
    logger.handlers[:] = []
    handler = RotatingFileHandler(
        str(log_path), maxBytes=LOG_BYTES,
        backupCount=LOG_BACKUPS, encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logger.addHandler(handler)
    return logger


def _progress(logger: logging.Logger, message: str) -> None:
    """Show live CLI progress and retain the same event in the rotating log."""
    logger.info("%s", message)
    print("retention.progress {}".format(message), file=sys.stderr, flush=True)


def _due_state(path: Path, now: float) -> tuple[bool, str | None]:
    """Return due status, treating malformed state as due and recording a warning."""
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            return True, "malformed-due-state"
        state = json.loads(path.read_text(encoding="utf-8"))
        last_run = float(state["last_success"])
        if not (last_run >= 0 and last_run <= now + 300):
            return True, "malformed-due-state"
        return now - last_run >= DUE_INTERVAL_SECONDS, None
    except FileNotFoundError:
        return True, None
    except (OSError, ValueError, KeyError, TypeError):
        return True, "malformed-due-state"


def _record(repo: Path, result: dict[str, object]) -> Path:
    """Persist a unique, immutable run receipt under the reserved retention root."""
    logs = _logs_root(repo)
    receipt_dir = logs / "retention-runs"
    try:
        receipt_dir.mkdir(mode=0o700)
    except FileExistsError:
        pass
    info = receipt_dir.lstat()
    if (stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode)
            or info.st_dev != logs.stat().st_dev):
        raise OSError("unsafe retention receipt directory")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    path = receipt_dir / (stamp + "-" + uuid.uuid4().hex + ".json")
    _atomic_json(path, result)
    return path


def _plain_directory(path: Path, label: str) -> Path:
    """Require an existing real directory without symlinked path components."""
    candidate = path.expanduser().absolute()
    try:
        candidate.lstat()
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise ValueError("{} is missing or unreadable".format(label)) from error
    if not candidate.is_dir() or candidate.is_symlink() or resolved != candidate:
        raise ValueError("{} must be a canonical directory without symlinks".format(label))
    return candidate


def _run(args: argparse.Namespace, logger: logging.Logger) -> tuple[int, dict[str, object]]:
    try:
        repo = _plain_directory(args.repo, "repository")
    except ValueError:
        return 2, {"status": "error", "reason": "repo-not-directory", "repo": str(args.repo)}
    now = time.time()
    apply = bool(args.apply)
    result: dict[str, object] = {
        "format": 1, "started_at": now, "repo": str(repo),
        "mode": "apply" if apply else "dry-run",
        "budget_seconds": args.budget_seconds,
    }
    lock_path = repo / ".logs" / "retention-run.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor: int | None = None
    try:
        _logs_root(repo)
        descriptor = os.open(str(lock_path), flags, 0o600)
        lock_info = os.fstat(descriptor)
        if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_dev != lock_path.parent.stat().st_dev:
            raise OSError("unsafe retention run lock")
    except OSError as error:
        if descriptor is not None:
            os.close(descriptor)
        result.update(status="error", reason="run-lock-unavailable", detail=str(error))
        logger.exception("run-lock-unavailable")
        return 2, result
    try:
        try:
            assert descriptor is not None
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            result.update(status="skipped", reason="another-run-active")
            logger.warning("skipped another-run-active")
            return 0, result

        due_path = repo / ".logs" / "retention-due.json"
        due, warning = (True, None) if args.force_due else _due_state(due_path, now)
        if warning:
            logger.warning("%s", warning)
            result["warning"] = warning
        if not due:
            result.update(status="skipped", reason="not-due")
            logger.info("skipped not-due")
            return 0, result

        deadline = time.monotonic() + args.budget_seconds
        # The signal is a hard wall-clock guard for subprocess and filesystem
        # operations; each policy module also checks the same monotonic deadline.
        previous = signal.signal(signal.SIGALRM, _timeout_handler)
        signal.setitimer(signal.ITIMER_REAL, args.budget_seconds)
        try:
            _progress(logger, "started mode={}".format(result["mode"]))
            _progress(logger, "starting SQLite backup retention")
            result["backups"] = backup_plan(
                args.backup_root.expanduser().absolute(), now=now, apply=apply,
                deadline=deadline,
            )
            _progress(logger, "completed backup retention")
            if time.monotonic() < deadline:
                _progress(logger, "starting build cache retention")
                result["caches"] = evict(
                    repo, budget=args.cache_budget_bytes, now=now, apply=apply,
                    deadline=deadline,
                )
            else:
                raise DeadlineExceeded("retention wall-clock budget exceeded")
            _progress(logger, "completed caches status={}".format(result["caches"].get("status")))
            if time.monotonic() >= deadline:
                raise DeadlineExceeded("retention wall-clock budget exceeded")
            archive = repo / ".logs" / "retained-evidence" / ("weekly-" + str(int(now)))
            _progress(logger, "starting evidence retention")
            result["evidence"] = compact(
                repo, archive, now=now, apply=apply, deadline=deadline,
            )
            _progress(logger, "completed evidence status={}".format(result["evidence"].get("status")))
            finished_at = time.time()
            result.update(status="complete", finished_at=finished_at)
            if apply:
                result["due_state_candidate"] = finished_at
            _progress(logger, "completed status=complete")
            return 0, result
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
    except TimeoutError as error:
        result.update(status="partial", reason="budget-exhausted", detail=str(error), finished_at=time.time())
        logger.error("budget-exhausted")
        return 3, result
    except Exception as error:
        result.update(status="error", reason="policy-error", detail=str(error), finished_at=time.time())
        logger.exception("policy-error")
        return 2, result
    finally:
        assert descriptor is not None
        os.close(descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="report without deleting (default)")
    mode.add_argument("--apply", action="store_true", help="apply retention decisions")
    parser.add_argument("--force-due", action="store_true", help="run even if the weekly interval has not elapsed")
    parser.add_argument("--budget-seconds", type=float, default=BUDGET_SECONDS)
    parser.add_argument("--cache-budget-bytes", type=int, default=BUDGET_BYTES)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument(
        "--backup-root", type=Path,
        default=Path.home() / "Library" / "Application Support" / "Wilted",
    )
    parser.add_argument("--restore", nargs=2, metavar=("ARCHIVE", "DESTINATION"),
                        help="restore a verified archive into a new directory")
    parser.add_argument("--restore-snapshot", nargs=2, metavar=("EXPORT_DIR", "DESTINATION"),
                        help="restore a source-member snapshot export into a new directory")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if not math.isfinite(args.budget_seconds) or args.budget_seconds <= 0:
        parser.error("--budget-seconds must be greater than 0")
    restore_mode = bool(args.restore or args.restore_snapshot)
    if restore_mode and args.budget_seconds > MAX_RESTORE_BUDGET_SECONDS:
        parser.error("restore --budget-seconds cannot exceed 86400")
    if not restore_mode and args.budget_seconds > MAX_BUDGET_SECONDS:
        parser.error("scheduled --budget-seconds cannot exceed 300")
    if args.cache_budget_bytes < 0:
        parser.error("--cache-budget-bytes must be nonnegative")
    try:
        repo = _plain_directory(args.repo, "repository")
    except ValueError:
        print(json.dumps({"status": "error", "reason": "repo-not-directory"}), file=sys.stderr)
        return 2
    if args.restore and args.restore_snapshot:
        parser.error("--restore and --restore-snapshot are mutually exclusive")
    if (args.restore or args.restore_snapshot) and args.apply:
        parser.error("restore options cannot be combined with --apply")
    try:
        logger = _configure_logging(repo)
        if args.restore or args.restore_snapshot:
            restore_args = args.restore if args.restore else args.restore_snapshot
            archive, destination = map(Path, restore_args)
            previous = signal.signal(signal.SIGALRM, _timeout_handler)
            signal.setitimer(signal.ITIMER_REAL, args.budget_seconds)
            try:
                _progress(logger, "starting {} restore".format(
                    "archive" if args.restore else "source snapshot",
                ))
                if args.restore:
                    manifest = restore_archive(archive.expanduser(), destination.expanduser())
                    restored_count = len(manifest["files"])
                    count_key = "files"
                else:
                    manifest = restore_snapshot(archive.expanduser(), destination.expanduser())
                    restored_count = int(manifest["members"])
                    count_key = "members"
                result: dict[str, object] = {"status": "restored", count_key: restored_count}
                if not args.restore:
                    result["container_recreated"] = False
                status = 0
                _progress(logger, "completed restore")
            except TimeoutError as error:
                result = {"status": "partial", "reason": "budget-exhausted", "detail": str(error)}
                status = 3
            except Exception as error:
                result = {"status": "error", "reason": "restore-failed", "detail": str(error)}
                status = 2
                logger.exception("restore-failed")
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, previous)
        else:
            status, result = _run(args, logger)
        due_candidate = result.pop("due_state_candidate", None)
        try:
            receipt = _record(repo, result)
            result["receipt"] = str(receipt)
        except Exception:
            logger.exception("receipt-write-failed")
            print(json.dumps({"status": "error", "reason": "receipt-write-failed"}), file=sys.stderr)
            return 2
        if due_candidate is not None:
            try:
                _atomic_json(repo / ".logs" / "retention-due.json", {"last_success": due_candidate})
                result["due_state_updated"] = True
            except OSError:
                logger.exception("due-state-write-failed")
                print(json.dumps({"status": "error", "reason": "due-state-write-failed",
                                  "receipt": str(receipt)}), file=sys.stderr)
                return 2
        print(json.dumps(result, indent=2, sort_keys=True))
        return status
    except (OSError, ValueError) as error:
        print(json.dumps({"status": "error", "reason": "startup-failed", "detail": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
