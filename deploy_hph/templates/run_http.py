# run_http.py — HTTP entry point for hosting the MCP server behind IIS.
# Reuses the existing FastMCP app from app/server.py (no source files modified).
#
# Under HttpPlatformHandler, IIS launches this process and assigns it a private
# port via %HTTP_PLATFORM_PORT%; the web.config maps that to MCP_PORT, which is
# read below. IIS reverse-proxies public requests to this loopback port.
import os

from app.server import mcp

# Bind to loopback only; IIS (HttpPlatformHandler) is the sole public entry point.
mcp.settings.host = os.getenv("MCP_HOST", "127.0.0.1")
mcp.settings.port = int(os.getenv("MCP_PORT", "8000"))
# Streamable HTTP is served at this path (final URL: http://host:port/mcp).
mcp.settings.streamable_http_path = os.getenv("MCP_PATH", "/mcp")

if __name__ == "__main__":
    # Streamable HTTP is the current MCP HTTP transport (served by uvicorn,
    # which HttpPlatformHandler does NOT replace).
    mcp.run(transport="streamable-http")
