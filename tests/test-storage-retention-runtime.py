#!/usr/bin/env python3
"""Exercise runtime receipts, due-state, bounds and LaunchAgent activation."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from retention.bundles import export_bundle
from retention.core import archive_paths


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fake_launchctl(path: Path, trace: Path, *, fail: str = "", print_missing: bool = False) -> None:
    """Write an executable launchctl fixture with one injectable failure."""
    script = "\n".join((
        "#!/bin/sh",
        "printf '%s\\n' \"$*\" >> {}".format(shlex.quote(str(trace))),
        "if [ \"$1\" = print ] && [ {} = 1 ]; then exit 17; fi".format(
            "1" if print_missing else "0",
        ),
        "if [ \"$1\" = {} ]; then exit 18; fi".format(shlex.quote(fail)),
        "exit 0",
        "",
    ))
    path.write_text(script, encoding="utf-8")
    path.chmod(0o755)


def main() -> int:
    runner = load("storage_retention_runtime", ROOT / "scripts/storage-retention.py")
    installer = load("install_storage_retention", ROOT / "scripts/install-storage-retention.py")
    with tempfile.TemporaryDirectory(prefix="retention-runtime-") as raw:
        base = Path(raw).resolve()
        repo = base / "repo"
        repo.mkdir()
        repo = repo.resolve()
        (repo / "scripts").mkdir()
        (repo / "scripts/run-storage-retention.sh").write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        backup = base / "Wilted"
        backup.mkdir()
        backup = backup.resolve()
        repo_link = base / "repo-link"
        repo_link.symlink_to(repo)
        try:
            runner._plain_directory(repo_link, "repository")
        except ValueError:
            pass
        else:
            raise AssertionError("repository symlink was accepted")
        lock_repo = base / "lock-repo"
        lock_repo.mkdir()
        lock_repo = lock_repo.resolve()
        (lock_repo / ".logs").mkdir()
        lock_target = base / "outside-lock-target"
        lock_target.write_bytes(b"keep")
        (lock_repo / ".logs/retention-run.lock").symlink_to(lock_target)
        lock_stdout = io.StringIO()
        lock_stderr = io.StringIO()
        with contextlib.redirect_stdout(lock_stdout), contextlib.redirect_stderr(lock_stderr):
            lock_status = runner.main(["--repo", str(lock_repo), "--backup-root", str(backup)])
        lock_result = json.loads(lock_stdout.getvalue())
        assert lock_status == 2 and lock_result["reason"] == "run-lock-unavailable"
        assert Path(lock_result["receipt"]).is_file()
        assert lock_target.read_bytes() == b"keep"
        default = runner._parser().parse_args(["--repo", str(repo)])
        assert default.backup_root == Path.home() / "Library" / "Application Support" / "Wilted"
        assert default.apply is False
        parser_error = io.StringIO()
        try:
            with contextlib.redirect_stderr(parser_error):
                runner.main(["--repo", str(repo), "--budget-seconds", "0"])
        except SystemExit as error:
            assert error.code == 2
        else:
            raise AssertionError("non-positive budget was accepted")
        assert "must be greater than 0" in parser_error.getvalue()
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                runner.main(["--repo", str(repo), "--budget-seconds", "301"])
            except SystemExit as error:
                assert error.code == 2
            else:
                raise AssertionError("scheduled budget over 300 seconds was accepted")

        calls = []
        runner.compact = lambda *a, **k: calls.append("evidence") or {"status": "dry-run"}
        runner.evict = lambda *a, **k: calls.append("caches") or {"status": "dry-run"}
        runner.backup_plan = lambda *a, **k: calls.append("backups") or {"backups": []}
        logger = runner._configure_logging(repo)

        args = runner._parser().parse_args([
            "--repo", str(repo), "--backup-root", str(backup), "--budget-seconds", "5",
        ])
        status, result = runner._run(args, logger)
        assert status == 0 and result["status"] == "complete"
        assert calls == ["backups", "caches", "evidence"]
        assert not (repo / ".logs/retention-due.json").exists(), "dry run must not advance due-state"

        due_path = repo / ".logs/retention-due.json"
        due_path.write_text(json.dumps({"last_success": time.time()}), encoding="utf-8")
        apply_args = runner._parser().parse_args([
            "--apply", "--repo", str(repo), "--backup-root", str(backup),
        ])
        status, result = runner._run(apply_args, logger)
        assert status == 0 and result["reason"] == "not-due"
        assert calls == ["backups", "caches", "evidence"], "not-due runs must skip policy handlers"
        assert json.loads(due_path.read_text())["last_success"] > 0

        due_path.write_text("not-json", encoding="utf-8")
        status, result = runner._run(args, logger)
        assert status == 0 and result["warning"] == "malformed-due-state"

        # Failure or timeout never advances the weekly due marker.
        due_path.write_text(json.dumps({"last_success": time.time() - 8 * 86400}), encoding="utf-8")
        previous_due = due_path.read_bytes()
        runner.compact = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("fixture failure"))
        status, result = runner._run(apply_args, logger)
        assert status == 2 and result["status"] == "error"
        assert due_path.read_bytes() == previous_due

        runner.compact = lambda *a, **k: time.sleep(1)
        short_args = runner._parser().parse_args([
            "--apply", "--force-due", "--repo", str(repo), "--backup-root", str(backup),
            "--budget-seconds", "0.1",
        ])
        status, result = runner._run(short_args, logger)
        assert status == 3 and result["reason"] == "budget-exhausted"
        assert due_path.read_bytes() == previous_due

        calls.clear()
        runner.backup_plan = lambda *a, **k: calls.append("backups") or {"backups": []}
        runner.evict = lambda *a, **k: calls.append("caches") or {"status": "evictable"}

        def compact_timeout(*_args, **_kwargs):
            calls.append("evidence")
            raise runner.DeadlineExceeded("fixture deadline")

        runner.compact = compact_timeout
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = runner.main([
                "--apply", "--force-due", "--repo", str(repo), "--backup-root", str(backup),
            ])
        timeout_result = json.loads(stdout.getvalue())
        assert status == 3 and timeout_result["status"] == "partial"
        assert calls == ["backups", "caches", "evidence"]
        assert due_path.read_bytes() == previous_due
        assert json.loads(Path(timeout_result["receipt"]).read_text())["reason"] == "budget-exhausted"

        runner.compact = lambda *a, **k: {"status": "removed"}
        success_args = runner._parser().parse_args([
            "--apply", "--force-due", "--repo", str(repo), "--backup-root", str(backup),
        ])
        status, result = runner._run(success_args, logger)
        assert status == 0 and result["status"] == "complete"
        assert result["due_state_candidate"] >= result["started_at"]
        assert due_path.read_bytes() == previous_due, "policy result alone must not advance due-state"
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = runner.main([
                "--apply", "--force-due", "--repo", str(repo), "--backup-root", str(backup),
            ])
        assert status == 0
        final = json.loads(stdout.getvalue())
        assert final["due_state_updated"] is True
        assert "due_state_candidate" not in json.loads(Path(final["receipt"]).read_text())
        assert json.loads(due_path.read_text())["last_success"] >= final["started_at"]

        # main creates durable receipts for skipped runs in the reserved root.
        due_path.write_text(json.dumps({"last_success": time.time()}), encoding="utf-8")
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            status = runner.main(["--apply", "--repo", str(repo), "--backup-root", str(backup)])
        assert status == 0
        printed = json.loads(stdout.getvalue())
        receipt = Path(printed["receipt"])
        assert receipt.is_file() and receipt.parent.name == "retention-runs"
        assert json.loads(receipt.read_text())["reason"] == "not-due"

        source = base / "restore-source.txt"
        source.write_bytes(b"restore through the policy CLI")
        archive = base / "restore-archive"
        archive_paths([source], base, archive)
        destination = base / "restored"
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = runner.main([
                "--repo", str(repo), "--budget-seconds", "301",
                "--restore", str(archive), str(destination),
            ])
        assert status == 0 and json.loads(stdout.getvalue())["status"] == "restored"
        assert (destination / source.name).read_bytes() == source.read_bytes()
        assert "starting archive restore" in stderr.getvalue()

        source_archive = base / "source.zip"
        with zipfile.ZipFile(source_archive, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
            zipped.writestr("nested/record.txt", "source archive member")
        snapshot_dir = base / "exports/source-snapshot"
        snapshot_dir.parent.mkdir()
        export_bundle(source_archive, snapshot_dir)
        restored_source = base / "restored-source"
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = runner.main([
                "--repo", str(repo), "--restore-snapshot", str(snapshot_dir), str(restored_source),
            ])
        restored_result = json.loads(stdout.getvalue())
        assert status == 0 and restored_result["status"] == "restored"
        assert restored_result["container_recreated"] is False
        assert (restored_source / "nested/record.txt").read_text() == "source archive member"
        assert "starting source snapshot restore" in stderr.getvalue()

        wrapper = subprocess.run(
            ["/bin/bash", str(ROOT / "scripts/run-storage-retention.sh"), "--help"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10, check=False,
        )
        assert wrapper.returncode == 0 and "--restore-snapshot" in wrapper.stdout

        # Installer render stays read-only and activates only via the fake CLI.
        output = base / "launch-agents/com.wilted.storage-retention.plist"
        render = io.StringIO()
        with contextlib.redirect_stdout(render):
            assert installer.main(["--repo", str(repo)]) == 0
        rendered = plistlib.loads(render.getvalue().encode())
        assert rendered["RunAtLoad"] is True and rendered["StartInterval"] == 604800
        assert rendered["ProgramArguments"] == ["/bin/bash", str(repo / "scripts/run-storage-retention.sh"), "--apply"]
        assert not output.exists(), "render must not install"

        fake = base / "launchctl"
        trace = base / "launchctl.trace"
        fake_launchctl(fake, trace)
        with contextlib.redirect_stdout(io.StringIO()):
            assert installer.main([
                "--apply", "--activate", "--repo", str(repo), "--output", str(output),
                "--launchctl", str(fake),
            ]) == 0
        installed = plistlib.loads(output.read_bytes())
        assert installed["StandardOutPath"] == "/dev/null"
        commands = trace.read_text().splitlines()
        assert [line.split()[0] for line in commands] == ["print", "bootout", "enable", "bootstrap", "kickstart"]
        assert Path(installed["ProgramArguments"][1]).is_file()

        # A fresh LaunchAgent is enabled without attempting bootout.
        fresh_trace = base / "launchctl-fresh.trace"
        fresh_fake = base / "launchctl-fresh"
        fresh_target = base / "fresh/com.wilted.storage-retention.plist"
        fake_launchctl(fresh_fake, fresh_trace, print_missing=True)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            fresh_status = installer.main([
                "--apply", "--activate", "--repo", str(repo), "--output", str(fresh_target),
                "--launchctl", str(fresh_fake),
            ])
        assert fresh_status == 0
        assert [line.split()[0] for line in fresh_trace.read_text().splitlines()] == [
            "print", "enable", "bootstrap", "kickstart",
        ]

        # Failures stop activation before any later launchctl action.
        failure_calls = {
            "bootout": ["print", "bootout"],
            "enable": ["print", "bootout", "enable"],
            "bootstrap": ["print", "bootout", "enable", "bootstrap"],
            "kickstart": ["print", "bootout", "enable", "bootstrap", "kickstart"],
        }
        for command, expected in failure_calls.items():
            failed_trace = base / ("launchctl-fail-" + command + ".trace")
            failed_fake = base / ("launchctl-fail-" + command)
            failed_target = base / ("failed" + command + ".plist")
            fake_launchctl(failed_fake, failed_trace, fail=command)
            failure_error = io.StringIO()
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(failure_error):
                failed_status = installer.main([
                    "--apply", "--activate", "--repo", str(repo), "--output", str(failed_target),
                    "--launchctl", str(failed_fake),
                ])
            assert failed_status == 2
            assert [line.split()[0] for line in failed_trace.read_text().splitlines()] == expected
            if command == "bootstrap":
                assert "agent remains unloaded" in failure_error.getvalue()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
