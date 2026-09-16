"""Logging configuration for wilted.

Sets up a RotatingFileHandler at /tmp/wilted.log (1 MB max, 2 backups).
WARNING+ is always active; DEBUG requires --debug flag or WILTED_DEBUG=1.

Usage in any module:
    import logging
    logger = logging.getLogger(__name__)
"""

import logging
from logging.handlers import RotatingFileHandler

LOG_PATH = "/tmp/wilted.log"
LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s: %(message)s"
LOG_DATE_FORMAT = "%Y-%m-%dT%H:%M:%SZ"


def setup_logging(debug: bool = False) -> None:
    """Configure root logger with file handler and optional console debug output.

    Args:
        debug: If True, set root level to DEBUG and add a stderr StreamHandler.
               Otherwise, root level is WARNING (file only).
    """
    root = logging.getLogger()
    level = logging.DEBUG if debug else logging.WARNING
    root.setLevel(level)

    formatter = logging.Formatter(LOG_FORMAT, datefmt=LOG_DATE_FORMAT)

    # File handler — WARNING+ always, or DEBUG when debug=True.
    file_handler = RotatingFileHandler(
        LOG_PATH,
        maxBytes=1024 * 1024,  # 1 MB
        backupCount=2,
        encoding="utf-8",
    )
    file_handler.setLevel(level)
    file_handler.setFormatter(formatter)

    # Avoid duplicate handlers if called more than once.
    root.handlers.clear()
    root.addHandler(file_handler)

    if debug:
        console = logging.StreamHandler()
        console.setLevel(logging.DEBUG)
        console.setFormatter(formatter)
        root.addHandler(console)
