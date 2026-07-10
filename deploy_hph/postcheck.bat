@echo off
REM ==========================================================================
REM  postcheck.bat  (HttpPlatformHandler mode)
REM
REM  Post-deployment health check for the MCP server on IIS. Runs the read-only
REM  Diagnose-Mcp.ps1, which walks every link in the chain (files -> app pool ->
REM  application -> https binding -> cert -> DB reachability -> live /mcp request)
REM  and prints a SUGGESTED ACTIONS summary. Nothing is changed.
REM
REM  Run from an elevated (Administrator) prompt on the target server.
REM  The window stays open until you press a key / close it.
REM
REM  Usage:
REM    postcheck.bat
REM    postcheck.bat -Hostname sitgis.jioconnect.com -ProjectRoot D:\AZDeployPY\MCP-SERVER-main
REM ==========================================================================
setlocal
set "HERE=%~dp0"
echo Running MCP post-deploy check... (this can take up to ~90s on a cold start)
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%Diagnose-Mcp.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
echo [postcheck] finished (exit %RC%). Review the SUGGESTED ACTIONS above.
echo.
pause
endlocal
exit /b %RC%
