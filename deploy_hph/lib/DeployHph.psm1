<#
    DeployHph.psm1 — core, testable logic for deploying the MCP server on IIS
    using the HttpPlatformHandler (HPH) module.

    HPH mode vs. the ARR/NSSM mode (../deploy):
      * IIS (via HttpPlatformHandler) LAUNCHES and MANAGES the Python process,
        so there is NO Windows Service (NSSM) and NO ARR / URL Rewrite proxy.
      * You STILL need Python + uvicorn[standard] + starlette (HPH does not
        replace the ASGI server inside Python).
      * The IIS site's physical path IS the app directory (web.config with the
        httpPlatform handler lives there; run_http.py + app/ must be importable).

    Everything here is unit-testable without touching IIS/network/installers;
    state-changing actions run only via Invoke-Step when NOT in -DryRun.

    Targets Windows PowerShell 5.1 (ships with Windows Server).
#>

Set-StrictMode -Version Latest

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------

function Get-DeployRoot  { Split-Path $PSScriptRoot -Parent }               # deploy_hph
function Get-ProjectRoot { Split-Path (Get-DeployRoot) -Parent }            # project root (sibling of docs/)

# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------

function Get-DeploySettings {
    [CmdletBinding()]
    param([string]$Path)

    $projectRoot = Get-ProjectRoot

    $defaults = @{
        # --- Web / IIS ---
        Hostname        = 'sitgis.jioconnect.com'
        McpPath         = '/MCPserver'
        BindHost        = '127.0.0.1'          # process binds loopback; IIS is the public entry
        AppPort         = 8000                 # used ONLY for the optional standalone smoke-test
        IisSiteName     = 'MCPserver'
        AppPoolName     = 'MCPserver'          # defaults to IisSiteName
        IisPhysicalPath = ''                   # defaults to InstallPath (HPH serves the app dir)
        # --- Hosting mode ---
        IisMode         = 'application'        # 'site' = standalone IIS site; 'application' = app under ParentSite
        ParentSite      = 'Default Web Site'   # (application mode) parent site to nest the app under
        AppAlias        = 'MCPserver'          # (application mode) app alias -> public path is /<alias>
        # --- HTTPS binding (optional) ---
        EnableHttps     = 'true'               # 'true' to add an https binding using CertThumbprint
        CertThumbprint  = 'F66384A3FA2D37872D611CEA939FA92C49E73929' # thumbprint of a cert already in LocalMachine\My
        HttpsPort       = 443
        # --- App pool identity (optional) ---
        AppPoolIdentity = ''                   # e.g. 'DOMAIN\svc-mcp'; blank = ApplicationPoolIdentity
        AppPoolPassword = ''
        # --- App / paths ---
        InstallPath     = $projectRoot
        VenvPath        = ''                   # computed if empty
        StartupTimeLimit= 60                   # seconds HPH waits for the process to start
        StdoutLog       = '.\app\logs\httpplatform.log'
        # --- Offline installer bundle ---
        BundleDir       = ''                   # computed if empty (apps-py-iis)
        MinPythonVersion= '3.10'
        # --- Database (.env) ---
        DbHost          = 'localhost'
        DbPort          = 5432
        DbName          = 'gis'
        DbUser          = 'mcp_readonly'
        DbPassword      = ''
        DbSchema        = 'public'
        AutoSetupAll    = 'false'
        NeSchema        = ''
        NeTablePrefix   = 'ne'
        AutoSetupNe     = 'true'
    }

    if ($Path -and (Test-Path $Path)) {
        $override = & ([scriptblock]::Create((Get-Content -Raw -Path $Path)))
        if ($override -is [hashtable]) { foreach ($k in $override.Keys) { $defaults[$k] = $override[$k] } }
    }

    if ([string]::IsNullOrEmpty($defaults.VenvPath))        { $defaults.VenvPath = Join-Path $defaults.InstallPath '.venv' }
    if ([string]::IsNullOrEmpty($defaults.BundleDir))       { $defaults.BundleDir = Join-Path $projectRoot 'apps-py-iis' }
    if ([string]::IsNullOrEmpty($defaults.IisPhysicalPath)) { $defaults.IisPhysicalPath = $defaults.InstallPath }
    if ([string]::IsNullOrEmpty($defaults.AppPoolName))     { $defaults.AppPoolName = $defaults.IisSiteName }

    # In application mode the app is nested at /<alias>. HttpPlatformHandler forwards the
    # full original path to the process, so the ASGI streamable path MUST equal /<alias>.
    # Derive it to keep the two in sync and avoid a /<alias>/<mcp> double-path mismatch.
    if ($defaults.IisMode -eq 'application') {
        $defaults.McpPath = '/' + ("$($defaults.AppAlias)").TrimStart('/')
    }

    return $defaults
}

# --------------------------------------------------------------------------
# Check results
# --------------------------------------------------------------------------

function New-CheckResult {
    param([bool]$Passed, [string]$Detail = '', [switch]$Warning)
    [pscustomobject]@{ Passed=$Passed; Warning=[bool]$Warning; Detail=$Detail }
}

# --------------------------------------------------------------------------
# Low-level probes
# --------------------------------------------------------------------------

function Test-IsAdmin {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-CommandExists { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Get-PythonVersionString {
    if (-not (Test-CommandExists 'python')) { return $null }
    try { return (& python --version 2>&1 | Out-String).Trim() } catch { return $null }
}

function Test-PythonVersionMeetsMin {
    param([string]$VersionString, [string]$Min = '3.10')
    if ([string]::IsNullOrWhiteSpace($VersionString)) { return $false }
    $m = [regex]::Match($VersionString, '(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $m.Success) { return $false }
    $found = [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, ($(if ($m.Groups[3].Success) { $m.Groups[3].Value } else { '0' })))
    $mp = $Min.Split('.'); while ($mp.Count -lt 3) { $mp += '0' }
    return ($found -ge [version]($mp -join '.'))
}

function Test-WindowsFeatureEnabled {
    param([string]$FeatureName)
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
        return ($f.State -eq 'Enabled')
    } catch {
        try {
            if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
                $wf = Get-WindowsFeature -Name $FeatureName -ErrorAction Stop
                return ($wf -and $wf.Installed)
            }
        } catch {}
        return $false
    }
}

function Test-IisInstalled {
    if (Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue) { return $true }
    return (Test-Path "$env:SystemRoot\System32\inetsrv\appcmd.exe")
}

function Test-HttpPlatformHandlerInstalled {
    # The module registers globally; check appcmd module list, then the DLL as a fallback.
    $appcmd = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
    if (Test-Path $appcmd) {
        try { if ((& $appcmd list modules 2>$null | Out-String) -match 'httpPlatformHandler') { return $true } } catch {}
    }
    return (Test-Path "$env:SystemRoot\System32\inetsrv\httpplatformhandler.dll")
}

# --------------------------------------------------------------------------
# Prerequisite checklist (HPH)
# --------------------------------------------------------------------------

function Get-PrereqChecks {
    [CmdletBinding()]
    param([hashtable]$Settings)
    if (-not $Settings) { $Settings = Get-DeploySettings }
    $projectRoot = $Settings.InstallPath
    $min = $Settings.MinPythonVersion

    @(
        [pscustomobject]@{ Id='admin'; Name='Administrator rights'; Category='OS'; Optional=$false
            Test={ New-CheckResult -Passed (Test-IsAdmin) -Detail $(if (Test-IsAdmin) {'Running elevated'} else {'Run this as Administrator'}) } },

        [pscustomobject]@{ Id='os'; Name='Windows Server / Windows OS'; Category='OS'; Optional=$true
            Test={ New-CheckResult -Passed $true -Warning -Detail ("OS: " + (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption) } },

        [pscustomobject]@{ Id='iis'; Name='IIS (Web Server role)'; Category='IIS'; Optional=$false
            Test={ $ok=Test-IisInstalled; New-CheckResult -Passed $ok -Detail $(if($ok){'W3SVC / appcmd present'}else{'IIS not installed (Web-Server role)'}) } },

        [pscustomobject]@{ Id='iis-websockets'; Name='IIS WebSocket Protocol'; Category='IIS'; Optional=$true
            Test={ $ok=(Test-WindowsFeatureEnabled 'IIS-WebSockets') -or (Test-WindowsFeatureEnabled 'Web-WebSockets'); New-CheckResult -Passed $ok -Warning -Detail $(if($ok){'WebSockets enabled'}else{'Optional: enable for MCP streaming'}) } },

        [pscustomobject]@{ Id='iis-windows-auth'; Name='IIS Windows Authentication'; Category='IIS'; Optional=$true
            Test={ $ok=(Test-WindowsFeatureEnabled 'IIS-WindowsAuthentication') -or (Test-WindowsFeatureEnabled 'Web-Windows-Auth'); New-CheckResult -Passed $ok -Warning -Detail $(if($ok){'Windows Auth available'}else{'Optional: needed only for AD auth'}) } },

        [pscustomobject]@{ Id='httpplatform'; Name='IIS HttpPlatformHandler module'; Category='IIS'; Optional=$false
            Test={ $ok=Test-HttpPlatformHandlerInstalled; New-CheckResult -Passed $ok -Detail $(if($ok){'HttpPlatformHandler installed'}else{'Install HttpPlatformHandler (bundle: httpplatformhandler*.msi)'}) } },

        [pscustomobject]@{ Id='python'; Name="Python >= $min (64-bit)"; Category='Runtime'; Optional=$false
            Test={ $v=Get-PythonVersionString; $ok=Test-PythonVersionMeetsMin $v $min; New-CheckResult -Passed $ok -Detail $(if($v){$v}else{'python not found on PATH'}) }.GetNewClosure() },

        [pscustomobject]@{ Id='pip'; Name='pip available'; Category='Runtime'; Optional=$false
            Test={ $ok=$false; $d='pip not found'; if (Test-CommandExists 'python') { try { $d=(& python -m pip --version 2>&1 | Out-String).Trim(); $ok=($LASTEXITCODE -eq 0) } catch {} }; New-CheckResult -Passed $ok -Detail $d } },

        [pscustomobject]@{ Id='project-files'; Name='Project source present'; Category='App'; Optional=$false
            Test={ $ok=(Test-Path (Join-Path $projectRoot 'app\server.py')) -and (Test-Path (Join-Path $projectRoot 'requirements.txt')); New-CheckResult -Passed $ok -Detail $(if($ok){"Found app\server.py under $projectRoot"}else{"Missing app\server.py / requirements.txt under $projectRoot"}) }.GetNewClosure() },

        [pscustomobject]@{ Id='db-reachable'; Name='PostgreSQL port reachable'; Category='Database'; Optional=$true
            Test={ $ok=$false; $d='Skipped (set DbHost/DbPort)'; if ($Settings.DbHost -and $Settings.DbHost -ne 'localhost') { try { $t=Test-NetConnection -ComputerName $Settings.DbHost -Port $Settings.DbPort -WarningAction SilentlyContinue; $ok=$t.TcpTestSucceeded; $d="$($Settings.DbHost):$($Settings.DbPort) => $ok" } catch { $d=$_.Exception.Message } } else { $ok=$true }; New-CheckResult -Passed $ok -Warning -Detail $d }.GetNewClosure() }
    )
}

function Invoke-PrereqCheck {
    param([Parameter(Mandatory)]$Check)
    try { $res = & $Check.Test; if ($null -eq $res) { $res = New-CheckResult -Passed $false -Detail 'check returned nothing' } }
    catch { $res = New-CheckResult -Passed $false -Detail ("error: " + $_.Exception.Message) }
    $optional=$false; if ($Check.PSObject.Properties['Optional']) { $optional=[bool]$Check.Optional }
    $category=''; if ($Check.PSObject.Properties['Category']) { $category=[string]$Check.Category }
    [pscustomobject]@{ Id=$Check.Id; Name=$Check.Name; Category=$category; Optional=$optional; Passed=[bool]$res.Passed; Warning=[bool]$res.Warning; Detail=[string]$res.Detail }
}

function Write-PrereqReport {
    [CmdletBinding()]
    param([hashtable]$Settings)
    if (-not $Settings) { $Settings = Get-DeploySettings }
    Write-Host ""
    Write-Host "==== MCP Server on IIS (HttpPlatformHandler) - Prerequisite Check ====" -ForegroundColor Cyan
    Write-Host "Project: $($Settings.InstallPath)"
    Write-Host "Bundle : $($Settings.BundleDir)"
    $allRequiredOk=$true; $lastCat=''
    foreach ($chk in (Get-PrereqChecks -Settings $Settings)) {
        $r = Invoke-PrereqCheck $chk
        if ($r.Category -ne $lastCat) { Write-Host ""; Write-Host "[$($r.Category)]" -ForegroundColor DarkCyan; $lastCat=$r.Category }
        if ($r.Passed) { $tag='  OK  '; $c='Green' }
        elseif ($r.Optional) { $tag=' WARN '; $c='Yellow' }
        else { $tag=' FAIL '; $c='Red'; $allRequiredOk=$false }
        Write-Host ("  [{0}] {1,-34} {2}" -f $tag, $r.Name, $r.Detail) -ForegroundColor $c
    }
    Write-Host ""
    if ($allRequiredOk) { Write-Host "All REQUIRED prerequisites satisfied." -ForegroundColor Green }
    else { Write-Host "One or more REQUIRED prerequisites are missing. Run precheck.bat --install (with a bundle) to install them." -ForegroundColor Red }
    return $allRequiredOk
}

# --------------------------------------------------------------------------
# Offline installer bundle (HPH-relevant only)
# --------------------------------------------------------------------------

function Get-InstallerType {
    param([Parameter(Mandatory)][string]$FileName)
    switch -Regex ($FileName.ToLowerInvariant()) {
        '^python-.*\.exe$'                 { return 'python' }
        'vc_?redist.*\.exe$'               { return 'vcredist' }
        'httpplatform(handler)?.*\.msi$'   { return 'httpplatform' }
        '\.whl$'                           { return 'wheel' }
        default                            { return 'unknown' }
    }
}

function Resolve-Installers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $priority = @{ vcredist=0; python=1; httpplatform=2 }
    $items = Get-ChildItem -Path $Path -File -ErrorAction SilentlyContinue | ForEach-Object {
        $type = Get-InstallerType $_.Name
        if ($priority.ContainsKey($type)) { [pscustomobject]@{ Name=$_.Name; Path=$_.FullName; Type=$type; Priority=$priority[$type] } }
    }
    return @($items | Sort-Object Priority, Name)
}

function Get-SilentInstallCommand {
    param([Parameter(Mandatory)]$Installer)
    switch ($Installer.Type) {
        'python'       { return [pscustomobject]@{ Kind='exe'; Executable=$Installer.Path; Arguments=@('/quiet','InstallAllUsers=1','PrependPath=1','Include_test=0','Include_launcher=1') } }
        'vcredist'     { return [pscustomobject]@{ Kind='exe'; Executable=$Installer.Path; Arguments=@('/install','/quiet','/norestart') } }
        'httpplatform' { return [pscustomobject]@{ Kind='msi'; Executable='msiexec.exe'; Arguments=@('/i',('"{0}"' -f $Installer.Path),'/qn','/norestart') } }
        default        { throw "No silent install command for type '$($Installer.Type)'" }
    }
}

function Install-FromBundle {
    [CmdletBinding()]
    param([hashtable]$Settings, [switch]$DryRun)
    if (-not $Settings) { $Settings = Get-DeploySettings }
    $dir = $Settings.BundleDir
    Write-Host ""
    Write-Host "==== Installing prerequisites from bundle (HPH) ====" -ForegroundColor Cyan
    Write-Host "Bundle: $dir"
    if (-not (Test-Path $dir)) {
        Write-Host "Bundle directory not found: $dir" -ForegroundColor Red
        Write-Host "Create it and place: python-*.exe, httpplatformhandler*.msi, VC_redist*.exe, and any *.whl wheels." -ForegroundColor DarkYellow
        return @()
    }
    $installers = Resolve-Installers -Path $dir
    if ($installers.Count -eq 0) { Write-Host "No recognised HPH installers found in bundle." -ForegroundColor Yellow; return @() }

    $results = New-Object System.Collections.ArrayList
    foreach ($inst in $installers) {
        $cmd = Get-SilentInstallCommand $inst
        Write-Host ""
        Write-Host ("-> {0}  ({1})" -f $inst.Name, $inst.Type) -ForegroundColor White
        $line = "$($cmd.Executable) $($cmd.Arguments -join ' ')"
        if ($DryRun) { Write-Host "   [DRY-RUN] $line" -ForegroundColor DarkGray }
        else {
            $p = Start-Process -FilePath $cmd.Executable -ArgumentList $cmd.Arguments -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { Write-Host "   Installed (exit $($p.ExitCode))" -ForegroundColor Green }
            else { Write-Host "   Installer returned exit $($p.ExitCode)" -ForegroundColor Red }
        }
        [void]$results.Add([pscustomobject]@{ Name=$inst.Name; Type=$inst.Type; DryRun=[bool]$DryRun })
    }
    return $results
}

# --------------------------------------------------------------------------
# web.config (HttpPlatformHandler)
# --------------------------------------------------------------------------

function New-HphWebConfig {
    <#
        Returns the HttpPlatformHandler web.config XML as a string.
        IIS launches <PythonExe> run_http.py and assigns it a private port via
        %HTTP_PLATFORM_PORT%, which run_http.py reads from MCP_PORT.
    #>
    param([hashtable]$Settings, [Parameter(Mandatory)][string]$PythonExe)
    $s = $Settings
@"
<?xml version="1.0" encoding="UTF-8"?>
<!-- HttpPlatformHandler web.config for the MCP server. IIS launches and manages
     the Python process; no ARR / URL Rewrite / NSSM required. -->
<configuration>
  <system.webServer>
    <handlers>
      <add name="httpPlatformHandler" path="*" verb="*"
           modules="httpPlatformHandler" resourceType="Unspecified" />
    </handlers>
    <httpPlatform stdoutLogEnabled="true"
                  stdoutLogFile="$($s.StdoutLog)"
                  startupTimeLimit="$($s.StartupTimeLimit)"
                  processPath="$PythonExe"
                  arguments="run_http.py">
      <environmentVariables>
        <environmentVariable name="MCP_HOST" value="$($s.BindHost)" />
        <environmentVariable name="MCP_PORT" value="%HTTP_PLATFORM_PORT%" />
        <environmentVariable name="MCP_PATH" value="$($s.McpPath)" />
      </environmentVariables>
    </httpPlatform>
  </system.webServer>
</configuration>
"@
}

# --------------------------------------------------------------------------
# Deployment plan + execution (HPH)
# --------------------------------------------------------------------------

function New-DeployPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings)
    $s = $Settings
    $deploy  = Get-DeployRoot
    $project = $s.InstallPath
    $py      = Join-Path $s.VenvPath 'Scripts\python.exe'

    $specs = @(
        @('copy-run-http', 'Copy HTTP entry point (run_http.py) to project root',
          "Copy $deploy\templates\run_http.py -> $project\run_http.py",
          { Copy-Item (Join-Path $deploy 'templates\run_http.py') (Join-Path $project 'run_http.py') -Force }.GetNewClosure()),

        @('create-venv', 'Create Python virtual environment',
          "python -m venv $($s.VenvPath)",
          { if (-not (Test-Path $py)) { & python -m venv $s.VenvPath } }.GetNewClosure()),

        @('pip-install', 'Install Python dependencies (offline wheels if present) + HTTP extras',
          "$py -m pip install -r requirements.txt uvicorn[standard] starlette (HPH still needs uvicorn)",
          {
              $req = Join-Path $project 'requirements.txt'
              $findLinks = @(); if (Test-Path $s.BundleDir) { $findLinks = @('--find-links', $s.BundleDir) }
              & $py -m pip install --upgrade pip @findLinks
              & $py -m pip install @findLinks -r $req
              & $py -m pip install @findLinks 'uvicorn[standard]' starlette
          }.GetNewClosure()),

        @('write-env', 'Write runtime configuration (app\.env)',
          "Write DB + NE settings to $project\app\.env",
          { Write-EnvFile -Settings $s }.GetNewClosure()),

        @('smoke-test', 'Smoke-test the app boots (standalone, loopback)',
          "Start $py run_http.py on $($s.BindHost):$($s.AppPort)$($s.McpPath), expect a response, then stop it",
          { Test-HttpSmoke -Settings $s -Python $py }.GetNewClosure()),

        @('iis-apppool', 'Create IIS application pool (No Managed Code)',
          "Create app pool '$($s.AppPoolName)' (managedRuntimeVersion='')$(if($s.AppPoolIdentity){"; identity $($s.AppPoolIdentity)"})",
          { New-IisAppPool -Settings $s }.GetNewClosure()),

        @('iis-site',
          $(if ($s.IisMode -eq 'application') { 'Create IIS application under the parent site' } else { 'Create IIS site pointing at the app directory' }),
          $(if ($s.IisMode -eq 'application') {
                "Create application '$(("$($s.AppAlias)").TrimStart('/'))' under '$($s.ParentSite)' physicalPath=$($s.IisPhysicalPath) appPool=$($s.AppPoolName)"
            } else {
                "Create site '$($s.IisSiteName)' host $($s.Hostname):80 physicalPath=$($s.IisPhysicalPath) appPool=$($s.AppPoolName)"
            }),
          $(if ($s.IisMode -eq 'application') { { New-IisApplication -Settings $s }.GetNewClosure() } else { { New-IisSite -Settings $s }.GetNewClosure() })),

        @('web-config', 'Write HttpPlatformHandler web.config into the app directory',
          "Write HPH web.config -> $($s.IisPhysicalPath)\web.config (processPath=$py run_http.py, MCP_PORT=%HTTP_PLATFORM_PORT%)",
          { Set-Content -Path (Join-Path $s.IisPhysicalPath 'web.config') -Value (New-HphWebConfig -Settings $s -PythonExe $py) -Encoding UTF8 }.GetNewClosure()),

        @('https-binding', 'Add an HTTPS binding (SNI) using the configured certificate',
          "Add https binding *:$($s.HttpsPort):$($s.Hostname) (SNI) cert $($s.CertThumbprint) to '$(if ($s.IisMode -eq 'application') { $s.ParentSite } else { $s.IisSiteName })'",
          { Add-HttpsBinding -Settings $s }.GetNewClosure()),

        @('firewall', 'Add inbound firewall rules (80/443)',
          "New-NetFirewallRule HTTP(80) + HTTPS(443) inbound allow",
          { New-DeployFirewallRules }.GetNewClosure()),

        @('start-site', 'Start the app pool + site and trigger the process',
          "Start app pool '$($s.AppPoolName)' and site '$($s.IisSiteName)' (first request launches Python via HPH)",
          { Start-IisSite -Settings $s }.GetNewClosure())
    )

    # The https-binding step is only relevant when EnableHttps is turned on.
    if ($s.EnableHttps -ne 'true') { $specs = @($specs | Where-Object { $_[0] -ne 'https-binding' }) }

    $order=0
    $steps = foreach ($spec in $specs) { $order++; [pscustomobject]@{ Order=$order; Id=$spec[0]; Name=$spec[1]; DryRunText=$spec[2]; Action=$spec[3] } }
    return @($steps)
}

function Invoke-Step {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step, [switch]$DryRun)
    $header = ("[{0:00}] {1}" -f $Step.Order, $Step.Name)
    if ($DryRun) {
        Write-Host $header -ForegroundColor White
        Write-Host ("     [DRY-RUN] " + $Step.DryRunText) -ForegroundColor DarkGray
        return @($header, ("[DRY-RUN] " + $Step.DryRunText))
    }
    Write-Host $header -ForegroundColor White
    & $Step.Action
    Write-Host "     done." -ForegroundColor Green
    return @($header)
}

function Invoke-Deploy {
    [CmdletBinding()]
    param([hashtable]$Settings, [switch]$DryRun)
    if (-not $Settings) { $Settings = Get-DeploySettings }
    Write-Host ""
    Write-Host "==== MCP Server IIS Deployment - HttpPlatformHandler $(if($DryRun){'(DRY-RUN)'}) ====" -ForegroundColor Cyan
    Write-Host "Project : $($Settings.InstallPath)"
    if ($Settings.IisMode -eq 'application') {
        Write-Host "Target  : application '$($Settings.AppAlias)' under '$($Settings.ParentSite)'  Host: $($Settings.Hostname)  Pool: $($Settings.AppPoolName)"
    } else {
        Write-Host "Site    : $($Settings.IisSiteName)  Host: $($Settings.Hostname)  Pool: $($Settings.AppPoolName)"
    }
    $scheme = if ($Settings.EnableHttps -eq 'true') { 'https' } else { 'http' }
    Write-Host "URL     : $scheme`://$($Settings.Hostname)$($Settings.McpPath)  (IIS launches Python via HttpPlatformHandler)"
    Write-Host ""
    if (-not $DryRun) {
        $ok = Write-PrereqReport -Settings $Settings
        if (-not $ok) { throw "Prerequisites not satisfied. Run precheck.bat --install first, then retry." }
    }
    foreach ($step in (New-DeployPlan -Settings $Settings)) { Invoke-Step -Step $step -DryRun:$DryRun | Out-Null }
    Write-Host ""
    Write-Host "Deployment plan complete$(if($DryRun){' (dry-run, nothing changed)'}else{''})." -ForegroundColor Green
}

# --------------------------------------------------------------------------
# Action helpers (run only outside dry-run)
# --------------------------------------------------------------------------

function Write-EnvFile {
    param([hashtable]$Settings)
    $s = $Settings
    $content = @"
DB_HOST=$($s.DbHost)
DB_PORT=$($s.DbPort)
DB_NAME=$($s.DbName)
DB_USER=$($s.DbUser)
DB_PASSWORD=$($s.DbPassword)
DB_SCHEMA=$($s.DbSchema)
AUTO_SETUP_ALL_TABLES=$($s.AutoSetupAll)
NE_SCHEMA=$($s.NeSchema)
NE_TABLE_PREFIX=$($s.NeTablePrefix)
AUTO_SETUP_NE_TABLES=$($s.AutoSetupNe)
"@
    Set-Content -Path (Join-Path $s.InstallPath 'app\.env') -Value $content -Encoding UTF8
}

function Test-HttpSmoke {
    param([hashtable]$Settings, [string]$Python)
    $s = $Settings
    $env:MCP_HOST=$s.BindHost; $env:MCP_PORT="$($s.AppPort)"; $env:MCP_PATH=$s.McpPath
    $proc = Start-Process -FilePath $Python -ArgumentList 'run_http.py' -WorkingDirectory $s.InstallPath -PassThru -WindowStyle Hidden
    try {
        Start-Sleep 5
        try { Invoke-WebRequest -Uri "http://$($s.BindHost):$($s.AppPort)$($s.McpPath)" -TimeoutSec 10 -UseBasicParsing | Out-Null; Write-Host "     Smoke test: endpoint responded." -ForegroundColor Green }
        catch { if ($_.Exception.Response) { Write-Host "     Smoke test: endpoint live (HTTP $([int]$_.Exception.Response.StatusCode))." -ForegroundColor Green } else { throw "Smoke test failed: $($_.Exception.Message)" } }
    } finally { if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } }
}

function New-IisAppPool {
    param([hashtable]$Settings)
    $s = $Settings
    Import-Module WebAdministration -ErrorAction Stop
    if (-not (Test-Path "IIS:\AppPools\$($s.AppPoolName)")) { New-WebAppPool -Name $s.AppPoolName | Out-Null }
    Set-ItemProperty "IIS:\AppPools\$($s.AppPoolName)" managedRuntimeVersion ''    # No Managed Code (Python app)
    Set-ItemProperty "IIS:\AppPools\$($s.AppPoolName)" startMode 'AlwaysRunning'
    if ($s.AppPoolIdentity) {
        Set-ItemProperty "IIS:\AppPools\$($s.AppPoolName)" -Name processModel -Value @{ identityType='SpecificUser'; userName=$s.AppPoolIdentity; password=$s.AppPoolPassword }
    }
}

function New-IisSite {
    param([hashtable]$Settings)
    $s = $Settings
    New-Item -ItemType Directory -Force -Path $s.IisPhysicalPath | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $s.InstallPath 'app\logs') | Out-Null
    Import-Module WebAdministration -ErrorAction Stop
    if (-not (Get-Website -Name $s.IisSiteName -ErrorAction SilentlyContinue)) {
        New-Website -Name $s.IisSiteName -Port 80 -HostHeader $s.Hostname -PhysicalPath $s.IisPhysicalPath -ApplicationPool $s.AppPoolName | Out-Null
    } else {
        Set-ItemProperty "IIS:\Sites\$($s.IisSiteName)" applicationPool $s.AppPoolName
        Set-ItemProperty "IIS:\Sites\$($s.IisSiteName)" physicalPath $s.IisPhysicalPath
    }
}

function New-IisApplication {
    # Nest the MCP app as an APPLICATION under an existing parent site (e.g. 'Default Web Site').
    # Public URL becomes https://<Hostname>/<AppAlias>. HttpPlatformHandler forwards the full
    # path to the process (McpPath is derived to /<AppAlias> in Get-DeploySettings).
    param([hashtable]$Settings)
    $s = $Settings
    New-Item -ItemType Directory -Force -Path $s.IisPhysicalPath | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $s.InstallPath 'app\logs') | Out-Null
    Import-Module WebAdministration -ErrorAction Stop
    if (-not (Get-Website -Name $s.ParentSite -ErrorAction SilentlyContinue)) {
        throw "Parent site '$($s.ParentSite)' not found. Create it (or use IisMode='site') before deploying."
    }
    $alias = ("$($s.AppAlias)").TrimStart('/')
    if (-not (Get-WebApplication -Site $s.ParentSite -Name $alias -ErrorAction SilentlyContinue)) {
        New-WebApplication -Site $s.ParentSite -Name $alias -PhysicalPath $s.IisPhysicalPath -ApplicationPool $s.AppPoolName | Out-Null
    } else {
        $appNode = "IIS:\Sites\$($s.ParentSite)\$alias"
        Set-ItemProperty $appNode applicationPool $s.AppPoolName
        Set-ItemProperty $appNode physicalPath   $s.IisPhysicalPath
    }
}

function Add-HttpsBinding {
    # Add an https binding (SNI) to the target site and attach a cert already present in
    # LocalMachine\My. In application mode the binding lives on the ParentSite.
    param([hashtable]$Settings)
    $s = $Settings
    if (-not $s.CertThumbprint) { throw "EnableHttps is true but CertThumbprint is empty; set the thumbprint of a cert in LocalMachine\My." }
    Import-Module WebAdministration -ErrorAction Stop
    $site = if ($s.IisMode -eq 'application') { $s.ParentSite } else { $s.IisSiteName }
    $existing = Get-WebBinding -Name $site -Protocol https -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -eq "*:$($s.HttpsPort):$($s.Hostname)" }
    if (-not $existing) {
        New-WebBinding -Name $site -Protocol https -Port $s.HttpsPort -HostHeader $s.Hostname -SslFlags 1 | Out-Null
    }
    $binding = Get-WebBinding -Name $site -Protocol https -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -eq "*:$($s.HttpsPort):$($s.Hostname)" }
    if ($binding) { $binding.AddSslCertificate($s.CertThumbprint, 'My') }
}

function New-DeployFirewallRules {
    if (-not (Get-NetFirewallRule -DisplayName 'IIS HTTPS' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName 'IIS HTTPS' -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null }
    if (-not (Get-NetFirewallRule -DisplayName 'IIS HTTP'  -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName 'IIS HTTP'  -Direction Inbound -Protocol TCP -LocalPort 80  -Action Allow | Out-Null }
}

function Start-IisSite {
    param([hashtable]$Settings)
    $s = $Settings
    Import-Module WebAdministration -ErrorAction Stop
    Restart-WebAppPool -Name $s.AppPoolName -ErrorAction SilentlyContinue
    $site = if ($s.IisMode -eq 'application') { $s.ParentSite } else { $s.IisSiteName }
    Start-Website -Name $site -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function `
    Get-DeployRoot, Get-ProjectRoot, Get-DeploySettings, New-CheckResult, `
    Test-IsAdmin, Test-CommandExists, Get-PythonVersionString, Test-PythonVersionMeetsMin, `
    Test-WindowsFeatureEnabled, Test-IisInstalled, Test-HttpPlatformHandlerInstalled, `
    Get-PrereqChecks, Invoke-PrereqCheck, Write-PrereqReport, `
    Get-InstallerType, Resolve-Installers, Get-SilentInstallCommand, Install-FromBundle, `
    New-HphWebConfig, New-DeployPlan, Invoke-Step, Invoke-Deploy, `
    Write-EnvFile, Test-HttpSmoke, New-IisAppPool, New-IisSite, New-IisApplication, Add-HttpsBinding, New-DeployFirewallRules, Start-IisSite
