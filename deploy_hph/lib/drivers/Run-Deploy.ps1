param(
    [string]$SettingsPath,
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\DeployHph.psm1') -Force
if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot '..\..\config\deploy.settings.ps1' }
$settings = Get-DeploySettings -Path $SettingsPath

if (-not $DryRun -and -not (Test-IsAdmin)) {
    Write-Host "ERROR: deployment requires Administrator rights (IIS, app pool, firewall). Re-run elevated." -ForegroundColor Red
    exit 2
}

try {
    Invoke-Deploy -Settings $settings -DryRun:$DryRun
    exit 0
} catch {
    Write-Host ""
    Write-Host "DEPLOY FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
