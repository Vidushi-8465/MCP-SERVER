# Create the IIS site folder and copy web.config.
# Run PowerShell as Administrator. See docs/DEPLOYMENT_IIS_WINDOWS_SERVER.md §7.

$sitePath = "C:\inetpub\mcp"
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$configSource = Join-Path $repoRoot "deploy\inetpub\mcp\web.config"

New-Item -ItemType Directory -Force $sitePath | Out-Null
Copy-Item -Path $configSource -Destination (Join-Path $sitePath "web.config") -Force

Write-Host "Created $sitePath and copied web.config."
Write-Host "Next: add the IIS site in IIS Manager (site name: mcp, hostname: mcp.yourdomain.com)."
