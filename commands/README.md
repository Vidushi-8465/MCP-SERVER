# Deployment commands for MCPserver

Use these commands from an elevated PowerShell window.

1. Open PowerShell as Administrator.
2. Change to the project directory:
   ```powershell
   cd C:\Vidushi\mcp-server
   ```
3. Review the deployment settings:
   ```powershell
   Get-Content .\deploy_hph\config\deploy.settings.ps1
   ```
4. Preview the deployment plan:
   ```powershell
   .\deploy_hph\deploy.bat --dry-run
   ```
5. Run the deployment:
   ```powershell
   .\deploy_hph\deploy.bat
   ```
6. Verify the IIS application:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\deploy_hph\Diagnose-Mcp.ps1 -Hostname sitgis.jioconnect.com -AppAlias MCPserver
   ```

Expected URL:
- https://sitgis.jioconnect.com/MCPserver
