# run_http.py — HTTP entry point for hosting the MCP server behind IIS.
# Reuses the existing FastMCP app from app/server.py (no source files modified).
import os

from app.server import mcp

# Bind to loopback only; IIS (reverse proxy) is the sole public entry point.
mcp.settings.host = os.getenv("MCP_HOST", "127.0.0.1")
mcp.settings.port = int(os.getenv("MCP_PORT", "8000"))
# Streamable HTTP is served at this path (final URL: http://host:port/mcp).
mcp.settings.streamable_http_path = os.getenv("MCP_PATH", "/mcp")

if __name__ == "__main__":
    # Streamable HTTP is the current MCP HTTP transport.
    mcp.run(transport="streamable-http")
