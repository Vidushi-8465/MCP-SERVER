@echo off
REM Install McpServer Windows Service via NSSM. Run as Administrator. See §6.
setlocal

set "NSSM=C:\tools\nssm\nssm.exe"
set "APP=C:\apps\mcp-server"

if not exist "%NSSM%" (
    echo NSSM not found at %NSSM%. Install NSSM first (see docs §3.4).
    exit /b 1
)

if not exist "%APP%\.venv\Scripts\python.exe" (
    echo Python venv not found at %APP%\.venv. Run setup-venv.bat from the app folder first.
    exit /b 1
)

"%NSSM%" install McpServer "%APP%\.venv\Scripts\python.exe" "run_http.py"
"%NSSM%" set McpServer AppDirectory "%APP%"
"%NSSM%" set McpServer AppStdout "%APP%\app\logs\service-stdout.log"
"%NSSM%" set McpServer AppStderr "%APP%\app\logs\service-stderr.log"
"%NSSM%" set McpServer Start SERVICE_AUTO_START
"%NSSM%" set McpServer AppEnvironmentExtra "MCP_HOST=127.0.0.1" "MCP_PORT=8000" "MCP_PATH=/mcp"

REM Uncomment and set credentials to run under a domain service account:
REM "%NSSM%" set McpServer ObjectName "DOMAIN\svc-mcp" "P@ssword-from-vault"

net start McpServer
sc query McpServer

endlocal
