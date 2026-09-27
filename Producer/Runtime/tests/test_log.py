import logging
from logging.handlers import RotatingFileHandler

from wilted import PROJECT_ROOT
from wilted import log as log_module


def test_setup_logging_writes_warning_to_project_log(tmp_path, monkeypatch):
    expected_path = PROJECT_ROOT.parent.parent / ".logs" / "wilted.log"
    assert log_module.LOG_PATH == expected_path

    log_path = tmp_path / ".logs" / "wilted.log"
    monkeypatch.setattr(log_module, "LOG_PATH", log_path)

    root = logging.getLogger()
    original_level = root.level
    original_handlers = list(root.handlers)
    try:
        log_module.setup_logging()

        file_handlers = [handler for handler in root.handlers if isinstance(handler, RotatingFileHandler)]
        assert len(file_handlers) == 1
        assert file_handlers[0].baseFilename == str(log_path)
        assert log_path.parent.is_dir()

        logging.getLogger("test_log").warning("file logging check")
        file_handlers[0].flush()
        assert "file logging check" in log_path.read_text(encoding="utf-8")
    finally:
        for handler in list(root.handlers):
            if handler not in original_handlers:
                root.removeHandler(handler)
                handler.close()
        root.handlers[:] = original_handlers
        root.setLevel(original_level)
