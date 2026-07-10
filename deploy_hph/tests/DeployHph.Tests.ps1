<#
    DeployHph.Tests.ps1 — unit tests for lib/DeployHph.psm1 (HttpPlatformHandler mode).

    Pure/deterministic: no IIS, no network, no installs. System-changing actions
    are only exercised in -DryRun mode.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\TestHarness.ps1"

$ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\DeployHph.psm1'
Import-Module $ModulePath -Force

# Scratch bundle. Note: rewrite/arr/nssm are intentionally present to prove the
# HPH bundle IGNORES them (they are not needed in HttpPlatformHandler mode).
$Fixture = Join-Path $env:TEMP ("deployhph-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Fixture | Out-Null
@(
    'python-3.11.9-amd64.exe',
    'httpplatformhandler_amd64_en-US.msi',
    'VC_redist.x64.exe',
    'rewrite_amd64_en-US.msi',
    'nssm-2.24.zip',
    'asyncpg-0.29.0-cp311-cp311-win_amd64.whl',
    'readme.txt'
) | ForEach-Object { New-Item -ItemType File -Force -Path (Join-Path $Fixture $_) | Out-Null }

try {

    Describe 'Get-InstallerType (HPH) classifies files by name' {
        It 'detects python'          { Assert-Equal 'python' (Get-InstallerType 'python-3.11.9-amd64.exe') }
        It 'detects httpplatform'    { Assert-Equal 'httpplatform' (Get-InstallerType 'httpplatformhandler_amd64_en-US.msi') }
        It 'detects vc redist'       { Assert-Equal 'vcredist' (Get-InstallerType 'VC_redist.x64.exe') }
        It 'detects wheel'           { Assert-Equal 'wheel' (Get-InstallerType 'asyncpg-0.29.0-cp311-cp311-win_amd64.whl') }
        It 'ignores URL Rewrite (not needed for HPH)' { Assert-Equal 'unknown' (Get-InstallerType 'rewrite_amd64_en-US.msi') }
        It 'ignores NSSM (not needed for HPH)'        { Assert-Equal 'unknown' (Get-InstallerType 'nssm-2.24.zip') }
    }

    Describe 'Resolve-Installers (HPH) returns only HPH-relevant installers, ordered' {
        $found = @(Resolve-Installers -Path $Fixture)
        It 'finds exactly three (vcredist, python, httpplatform)' { Assert-Equal 3 $found.Count }
        It 'excludes rewrite/nssm/wheel/txt' {
            $types = $found | ForEach-Object { $_.Type }
            Assert-NotContains $types 'urlrewrite'
            Assert-NotContains $types 'nssm'
            Assert-NotContains $types 'wheel'
            Assert-NotContains $types 'unknown'
        }
        It 'orders vcredist < python < httpplatform' {
            $order = @($found | ForEach-Object { $_.Type })
            Assert-True ([array]::IndexOf($order,'vcredist') -lt [array]::IndexOf($order,'python'))
            Assert-True ([array]::IndexOf($order,'python')  -lt [array]::IndexOf($order,'httpplatform'))
        }
        It 'empty for a missing dir (no throw)' {
            Assert-Equal 0 (@(Resolve-Installers -Path (Join-Path $Fixture 'nope')).Count)
        }
    }

    Describe 'Get-SilentInstallCommand builds silent command lines' {
        It 'httpplatform msi uses msiexec /i /qn /norestart' {
            $c = Get-SilentInstallCommand ([pscustomobject]@{ Type='httpplatform'; Path='C:\x\hph.msi'; Name='hph.msi' })
            Assert-Equal 'msi' $c.Kind
            Assert-Equal 'msiexec.exe' $c.Executable
            Assert-Match ($c.Arguments -join ' ') '/i'
            Assert-Match ($c.Arguments -join ' ') '/qn'
            Assert-Match ($c.Arguments -join ' ') '/norestart'
        }
        It 'python exe uses /quiet InstallAllUsers PrependPath' {
            $c = Get-SilentInstallCommand ([pscustomobject]@{ Type='python'; Path='C:\x\python.exe'; Name='python.exe' })
            Assert-Equal 'exe' $c.Kind
            Assert-Match ($c.Arguments -join ' ') '/quiet'
            Assert-Match ($c.Arguments -join ' ') 'InstallAllUsers=1'
        }
        It 'vcredist exe uses /install /quiet /norestart' {
            $c = Get-SilentInstallCommand ([pscustomobject]@{ Type='vcredist'; Path='C:\x\vc.exe'; Name='vc.exe' })
            Assert-Equal 'exe' $c.Kind
            Assert-Match ($c.Arguments -join ' ') '/quiet'
        }
    }

    Describe 'Test-PythonVersionMeetsMin parses and compares versions' {
        It 'accepts 3.11.9 for min 3.10' { Assert-True  (Test-PythonVersionMeetsMin 'Python 3.11.9' '3.10') }
        It 'rejects 3.9.13'              { Assert-False (Test-PythonVersionMeetsMin 'Python 3.9.13' '3.10') }
        It 'rejects garbage'             { Assert-False (Test-PythonVersionMeetsMin 'nope' '3.10') }
    }

    Describe 'Get-PrereqChecks (HPH) lists the right checks' {
        $ids = (Get-PrereqChecks) | ForEach-Object { $_.Id }
        It 'includes admin'          { Assert-Contains $ids 'admin' }
        It 'includes iis'            { Assert-Contains $ids 'iis' }
        It 'includes httpplatform'   { Assert-Contains $ids 'httpplatform' }
        It 'includes python'         { Assert-Contains $ids 'python' }
        It 'includes project-files'  { Assert-Contains $ids 'project-files' }
        It 'does NOT require URL Rewrite' { Assert-NotContains $ids 'url-rewrite' }
        It 'does NOT require ARR'          { Assert-NotContains $ids 'arr' }
        It 'does NOT require NSSM'         { Assert-NotContains $ids 'nssm' }
        It 'every check has Id/Name/Test' {
            foreach ($c in (Get-PrereqChecks)) {
                Assert-NotNull $c.Id; Assert-NotNull $c.Name
                Assert-True ($c.Test -is [scriptblock])
            }
        }
    }

    Describe 'Invoke-PrereqCheck returns a structured, non-throwing result' {
        It 'passing check' {
            $r = Invoke-PrereqCheck ([pscustomobject]@{ Id='x'; Name='X'; Test={ New-CheckResult -Passed $true -Detail 'ok' } })
            Assert-True $r.Passed; Assert-Equal 'x' $r.Id
        }
        It 'throwing check becomes a failure' {
            $r = Invoke-PrereqCheck ([pscustomobject]@{ Id='y'; Name='Y'; Test={ throw 'boom' } })
            Assert-False $r.Passed; Assert-Match $r.Detail 'boom'
        }
    }

    Describe 'Get-DeploySettings (HPH) defaults' {
        $s = Get-DeploySettings
        It 'has an MCP path'                 { Assert-Equal '/mcp' $s.McpPath }
        It 'has an install path'             { Assert-NotNull $s.InstallPath }
        It 'site physical path defaults to the app dir (HPH serves the app)' {
            Assert-Equal $s.InstallPath $s.IisPhysicalPath
        }
        It 'merges overrides from a file' {
            $sf = Join-Path $Fixture 'settings.ps1'
            Set-Content -Path $sf -Encoding UTF8 -Value '@{ Hostname = "hph.test.local" }'
            Assert-Equal 'hph.test.local' (Get-DeploySettings -Path $sf).Hostname
        }
    }

    Describe 'New-DeployPlan (HPH) produces the right ordered steps' {
        $plan = @(New-DeployPlan -Settings (Get-DeploySettings))
        $ids = $plan | ForEach-Object { $_.Id }
        It 'copies run_http.py'    { Assert-Contains $ids 'copy-run-http' }
        It 'creates venv'          { Assert-Contains $ids 'create-venv' }
        It 'pip installs'          { Assert-Contains $ids 'pip-install' }
        It 'writes env'            { Assert-Contains $ids 'write-env' }
        It 'creates app pool'      { Assert-Contains $ids 'iis-apppool' }
        It 'creates site'          { Assert-Contains $ids 'iis-site' }
        It 'writes HPH web.config' { Assert-Contains $ids 'web-config' }
        It 'adds firewall'         { Assert-Contains $ids 'firewall' }
        It 'does NOT install a windows service (HPH manages the process)' { Assert-NotContains $ids 'install-service' }
        It 'does NOT enable ARR'   { Assert-NotContains $ids 'enable-arr' }
        It 'steps are strictly ordered with DryRunText' {
            $i=0; foreach ($s in $plan) { Assert-True ($s.Order -gt $i); $i=$s.Order; Assert-NotNull $s.DryRunText }
        }
    }

    Describe 'Invoke-Step honours -DryRun' {
        It 'does not run the action in dry-run' {
            $script:se = $false
            $step = [pscustomobject]@{ Order=1; Id='t'; Name='t'; DryRunText='would t'; Action={ $script:se=$true } }
            $out = Invoke-Step -Step $step -DryRun
            Assert-False $script:se
            Assert-Match ($out -join ' ') 'would t'
        }
        It 'runs the action when not dry-run' {
            $script:se2=$false
            $step = [pscustomobject]@{ Order=1; Id='t'; Name='t'; DryRunText='x'; Action={ $script:se2=$true } }
            Invoke-Step -Step $step | Out-Null
            Assert-True $script:se2
        }
    }

    Describe 'New-HphWebConfig renders a valid HttpPlatformHandler config' {
        $s = Get-DeploySettings
        $xml = New-HphWebConfig -Settings $s -PythonExe 'C:\app\.venv\Scripts\python.exe'
        It 'declares the httpPlatformHandler handler' { Assert-Match $xml 'httpPlatformHandler' }
        It 'points processPath at the venv python'    { Assert-Match $xml ([regex]::Escape('C:\app\.venv\Scripts\python.exe')) }
        It 'passes run_http.py as the argument'        { Assert-Match $xml 'run_http\.py' }
        It 'wires MCP_PORT to %HTTP_PLATFORM_PORT%'    { Assert-Match $xml 'HTTP_PLATFORM_PORT' }
        It 'sets the MCP path'                          { Assert-Match $xml ([regex]::Escape($s.McpPath)) }
        It 'is well-formed XML' { [void][xml]$xml }
    }

    Describe 'Get-DeploySettings (HPH) IIS hosting mode + HTTPS defaults' {
        $s = Get-DeploySettings
        It 'defaults to standalone site mode'          { Assert-Equal 'site' $s.IisMode }
        It 'defaults the parent site to Default Web Site' { Assert-Equal 'Default Web Site' $s.ParentSite }
        It 'defaults the application alias'            { Assert-Equal 'mcp' $s.AppAlias }
        It 'defaults HTTPS off'                        { Assert-Equal 'false' $s.EnableHttps }
        It 'has an empty cert thumbprint by default'   { Assert-Equal '' $s.CertThumbprint }
        It 'defaults the https port to 443'            { Assert-Equal 443 $s.HttpsPort }
    }

    Describe 'Get-DeploySettings (HPH) application mode derives the MCP path from the alias' {
        $sf = Join-Path $Fixture 'app-mode.ps1'
        Set-Content -Path $sf -Encoding UTF8 -Value '@{ IisMode = "application"; AppAlias = "gis" }'
        $s = Get-DeploySettings -Path $sf
        It 'sets McpPath to /<alias> so it matches the path HPH forwards' { Assert-Equal '/gis' $s.McpPath }
    }

    Describe 'New-DeployPlan (HPH) application mode targets the parent site' {
        $sf = Join-Path $Fixture 'plan-app.ps1'
        Set-Content -Path $sf -Encoding UTF8 -Value '@{ IisMode = "application"; ParentSite = "Default Web Site"; AppAlias = "mcp" }'
        $plan = @(New-DeployPlan -Settings (Get-DeploySettings -Path $sf))
        $site = $plan | Where-Object { $_.Id -eq 'iis-site' }
        It 'still has the iis-site step' { Assert-NotNull $site }
        It 'describes an application under the parent site' {
            Assert-Match $site.DryRunText "application 'mcp' under 'Default Web Site'"
        }
    }

    Describe 'New-DeployPlan (HPH) adds an https-binding step only when EnableHttps is true' {
        $off = @(New-DeployPlan -Settings (Get-DeploySettings)) | ForEach-Object { $_.Id }
        It 'omits https-binding by default' { Assert-NotContains $off 'https-binding' }

        $sf = Join-Path $Fixture 'https.ps1'
        Set-Content -Path $sf -Encoding UTF8 -Value '@{ EnableHttps = "true"; Hostname = "sitgis.jioconnect.com"; CertThumbprint = "ABC123"; IisMode = "application" }'
        $on  = @(New-DeployPlan -Settings (Get-DeploySettings -Path $sf))
        $ids = $on | ForEach-Object { $_.Id }
        It 'includes https-binding when enabled' { Assert-Contains $ids 'https-binding' }
        It 'the https step names the host and cert' {
            $h = $on | Where-Object { $_.Id -eq 'https-binding' }
            Assert-Match $h.DryRunText 'sitgis\.jioconnect\.com'
            Assert-Match $h.DryRunText 'ABC123'
        }
    }

    Describe 'IIS application + HTTPS helpers are exported' {
        It 'exports New-IisApplication' { Assert-NotNull (Get-Command New-IisApplication -ErrorAction SilentlyContinue) }
        It 'exports Add-HttpsBinding'   { Assert-NotNull (Get-Command Add-HttpsBinding -ErrorAction SilentlyContinue) }
    }

}
finally {
    Remove-Item -Recurse -Force $Fixture -ErrorAction SilentlyContinue
}

Invoke-TestSummary
