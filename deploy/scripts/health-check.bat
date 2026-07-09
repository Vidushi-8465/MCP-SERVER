@echo off
REM Quick deployment health checks. See docs/DEPLOYMENT_IIS_WINDOWS_SERVER.md §11 and Appendix B.
setlocal

echo === McpServer service ===
sc query McpServer

echo.
echo === Loopback port 8000 ===
powershell -NoProfile -Command "Test-NetConnection 127.0.0.1 -Port 8000 | Select-Object TcpTestSucceeded"

echo.
echo === HTTP endpoint ===
curl.exe -i http://127.0.0.1:8000/mcp

echo.
echo === App log (last 20 lines) ===
if exist "C:\apps\mcp-server\app\logs\mcp-server.log" (
    powershell -NoProfile -Command "Get-Content 'C:\apps\mcp-server\app\logs\mcp-server.log' -Tail 20"
) else (
    echo Log not found at C:\apps\mcp-server\app\logs\mcp-server.log
)

endlocal
