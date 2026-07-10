# Step-by-step deployment commands for your IIS setup
# Target URL: https://sitgis.jioconnect.com/MCPserver

$repo = 'C:\Vidushi\mcp-server'
Set-Location $repo

# 1) Open PowerShell as Administrator
# 2) Verify the deployment settings
Get-Content .\deploy_hph\config\deploy.settings.ps1

# 3) Run the dry-run deployment plan
cmd /c ".\deploy_hph\deploy.bat --dry-run"

# 4) Run the real deployment
cmd /c ".\deploy_hph\deploy.bat"

# 5) Optional: verify the IIS deployment
powershell -ExecutionPolicy Bypass -File .\deploy_hph\Diagnose-Mcp.ps1 -Hostname sitgis.jioconnect.com -AppAlias MCPserver

# 6) If needed, test the public URL directly
Invoke-WebRequest -Uri 'https://sitgis.jioconnect.com/MCPserver' -UseBasicParsing
