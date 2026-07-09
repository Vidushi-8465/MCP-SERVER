# Install the MCP server as a Windows Service using NSSM.
# Run PowerShell as Administrator. Adjust paths and credentials before use.
# See docs/DEPLOYMENT_IIS_WINDOWS_SERVER.md §6.

$nssm = "C:\tools\nssm\nssm.exe"
$app  = "C:\apps\mcp-server"

& $nssm install McpServer "$app\.venv\Scripts\python.exe" "run_http.py"
& $nssm set McpServer AppDirectory $app
& $nssm set McpServer AppStdout "$app\app\logs\service-stdout.log"
& $nssm set McpServer AppStderr "$app\app\logs\service-stderr.log"
& $nssm set McpServer Start SERVICE_AUTO_START
& $nssm set McpServer AppEnvironmentExtra "MCP_HOST=127.0.0.1" "MCP_PORT=8000" "MCP_PATH=/mcp"

# Run under the domain service account (least privilege):
# & $nssm set McpServer ObjectName "DOMAIN\svc-mcp" "P@ssword-from-vault"

Start-Service McpServer
Get-Service McpServer
