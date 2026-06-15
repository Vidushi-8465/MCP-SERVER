from __future__ import annotations

import logging
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
LOG_DIR = BASE_DIR / "logs"
LOG_FILE = LOG_DIR / "mcp-server.log"


def setup_logging() -> logging.Logger:
    LOG_DIR.mkdir(exist_ok=True)

    formatter = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    file_handler = logging.FileHandler(LOG_FILE, encoding="utf-8")
    file_handler.setFormatter(formatter)

    logger = logging.getLogger("mcp-server")
    logger.handlers.clear()
    logger.addHandler(file_handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False

    # MCP uses stdio for protocol traffic — never log to stdout/stderr.
    for name in ("mcp", "asyncpg", "asyncio", "root"):
        lib_logger = logging.getLogger(name)
        lib_logger.handlers.clear()
        if name != "root":
            lib_logger.addHandler(file_handler)
        lib_logger.propagate = False

    return logger
