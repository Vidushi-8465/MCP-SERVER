# run_http.py — HTTP entry point for hosting the MCP server behind IIS.
# Reuses the existing FastMCP app from app/server.py.
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from app.server import main

if __name__ == "__main__":
    main()
