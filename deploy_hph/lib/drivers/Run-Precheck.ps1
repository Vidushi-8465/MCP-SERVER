param(
    [string]$SettingsPath,
    [switch]$Install,   # also install missing prerequisites from the bundle, then re-verify
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\DeployHph.psm1') -Force
if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot '..\..\config\deploy.settings.ps1' }
$settings = Get-DeploySettings -Path $SettingsPath

if ($Install) {
    if (-not $DryRun -and -not (Test-IsAdmin)) {
        Write-Host "ERROR: installing prerequisites requires Administrator rights. Re-run elevated." -ForegroundColor Red
        exit 2
    }
    Install-FromBundle -Settings $settings -DryRun:$DryRun | Out-Null
    if ($DryRun) {
        Write-Host ""
        Write-Host "(dry-run: nothing was installed; skipping post-install verification)" -ForegroundColor DarkYellow
        exit 0
    }
}

# Always verify (this is the 'verify all' part).
$ok = Write-PrereqReport -Settings $settings
if ($ok) { exit 0 } else { exit 1 }
