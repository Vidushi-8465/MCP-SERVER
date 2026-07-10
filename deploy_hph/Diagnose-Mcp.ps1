<#
    Diagnose-Mcp.ps1 - read-only health check for the MCP server hosted on IIS
    (HttpPlatformHandler mode, as an application under a parent site).

    Run ON THE SERVER (elevated). Usually launched via postcheck.bat, or directly:
        cd <project-root>\deploy_hph
        .\Diagnose-Mcp.ps1

    Nothing is changed. It walks every link in the chain (files -> app pool ->
    application -> https binding -> cert -> DB reachability -> the actual /mcp
    request) and ends with a SUGGESTED ACTIONS summary.

    Override anything that differs from the defaults:
        .\Diagnose-Mcp.ps1 -Hostname sitgis.jioconnect.com -AppAlias mcp `
                           -ParentSite 'Default Web Site' -ProjectRoot 'D:\AZDeployPY\MCP-SERVER-main'
#>
[CmdletBinding()]
param(
    [string]$Hostname    = 'sitgis.jioconnect.com',
    [string]$AppAlias    = 'mcp',
    [string]$ParentSite  = 'Default Web Site',
    [string]$AppPoolName = 'mcp',
    [int]   $HttpsPort   = 443,
    [string]$ProjectRoot = '',    # auto-detected if empty
    [int]   $RequestTimeoutSec = 90
)

$ErrorActionPreference = 'Continue'
$script:Suggest = New-Object System.Collections.ArrayList
$script:FailCount = 0
$script:WarnCount = 0

function Suggest { param([string]$s) if ($s) { [void]$script:Suggest.Add($s) } }
function Line {
    param([string]$Status,[string]$Title,[string]$Detail='',[string]$Fix='')
    $color = switch ($Status) { 'PASS' {'Green'} 'FAIL' {'Red'} 'WARN' {'Yellow'} default {'Gray'} }
    if ($Status -eq 'FAIL') { $script:FailCount++ }
    if ($Status -eq 'WARN') { $script:WarnCount++ }
    Write-Host ("[{0}] {1}" -f $Status, $Title) -ForegroundColor $color
    if ($Detail) { $Detail -split "`n" | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray } }
    if ($Fix -and $Status -ne 'PASS') { Suggest $Fix }
}
function Head { param([string]$T) Write-Host ""; Write-Host "== $T ==" -ForegroundColor Cyan }

# --- Resolve project root -------------------------------------------------
if (-not $ProjectRoot) { $ProjectRoot = Split-Path $PSScriptRoot -Parent }
$webConfig = Join-Path $ProjectRoot 'web.config'
$runHttp   = Join-Path $ProjectRoot 'run_http.py'
$hphLog    = Join-Path $ProjectRoot 'app\logs\httpplatform.log'
$mcpLog    = Join-Path $ProjectRoot 'app\logs\mcp-server.log'
$envFile   = Join-Path $ProjectRoot 'app\.env'
$mcpPath   = '/' + $AppAlias.TrimStart('/')
$publicUrl = "https://$Hostname$mcpPath"

Write-Host "==== MCP post-deploy check ====" -ForegroundColor White
Write-Host "Project root : $ProjectRoot"
Write-Host "Public URL   : $publicUrl"
Write-Host "Parent site  : $ParentSite   App alias: $AppAlias   Pool: $AppPoolName"
Write-Host "Time         : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# --- 0. Environment -------------------------------------------------------
Head 'Environment'
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Line ($(if($isAdmin){'PASS'}else{'WARN'})) 'Running elevated' $(if($isAdmin){'yes'}else{'not elevated - some checks limited'}) 'Re-run in an elevated PowerShell / admin cmd.'
try { Import-Module WebAdministration -ErrorAction Stop; Line 'PASS' 'WebAdministration module loaded' }
catch { Line 'FAIL' 'WebAdministration module' $_.Exception.Message 'IIS may not be installed. Enable the Web-Server feature.'; return }

# --- 1. Deployed files ----------------------------------------------------
Head 'Deployed files'
Line ($(if(Test-Path $runHttp){'PASS'}else{'FAIL'}))   'run_http.py present'  $runHttp 'run deploy.bat (copy-run-http step).'
Line ($(if(Test-Path $webConfig){'PASS'}else{'FAIL'})) 'web.config present'   $webConfig 'run deploy.bat (web-config step).'
if (Test-Path $webConfig) {
    $wc = Get-Content -Raw $webConfig
    $m  = [regex]::Match($wc, 'MCP_PATH"\s*value="([^"]*)"')
    if ($m.Success) {
        $cfgPath = $m.Groups[1].Value
        Line ($(if($cfgPath -eq $mcpPath){'PASS'}else{'WARN'})) "web.config MCP_PATH = $cfgPath" $(if($cfgPath -ne $mcpPath){"expected $mcpPath"}) "Set MCP_PATH to $mcpPath in web.config, then Restart-WebAppPool $AppPoolName."
    }
    $pp = [regex]::Match($wc, 'processPath="([^"]*)"')
    if ($pp.Success) { Line ($(if(Test-Path $pp.Groups[1].Value){'PASS'}else{'FAIL'})) 'web.config python.exe exists' $pp.Groups[1].Value 're-create the venv (deploy create-venv step).' }
}
Line ($(if(Test-Path $envFile){'PASS'}else{'WARN'})) 'app\.env present' $(if(-not(Test-Path $envFile)){'no .env - DB settings missing'}) 'create app\.env (deploy write-env step).'

# --- 2. App pool ----------------------------------------------------------
Head 'IIS application pool'
if (Test-Path "IIS:\AppPools\$AppPoolName") {
    $pool = Get-Item "IIS:\AppPools\$AppPoolName"
    $state = (Get-WebAppPoolState $AppPoolName).Value
    Line ($(if($state -eq 'Started'){'PASS'}else{'FAIL'})) "App pool '$AppPoolName' state = $state" '' "Start-WebAppPool $AppPoolName"
    Line ($(if([string]::IsNullOrEmpty($pool.managedRuntimeVersion)){'PASS'}else{'WARN'})) "managedRuntimeVersion = '$($pool.managedRuntimeVersion)'" $(if($pool.managedRuntimeVersion){'should be empty (No Managed Code)'}) "Set-ItemProperty IIS:\AppPools\$AppPoolName managedRuntimeVersion ''"
    Line 'INFO' "identity = $($pool.processModel.identityType) $($pool.processModel.userName)"
} else { Line 'FAIL' "App pool '$AppPoolName' does not exist" '' 'run deploy.bat (iis-apppool step).' }

# --- 3. Application under parent site -------------------------------------
Head 'IIS application'
$site = Get-Website -Name $ParentSite -ErrorAction SilentlyContinue
Line ($(if($site){'PASS'}else{'FAIL'})) "Parent site '$ParentSite' exists" $(if($site){"state = $($site.State)"}) "create the parent site or set ParentSite correctly."
$app = Get-WebApplication -Site $ParentSite -Name $AppAlias.TrimStart('/') -ErrorAction SilentlyContinue
if ($app) { Line 'PASS' "Application '/$($AppAlias.TrimStart('/'))' exists" ("physicalPath = {0}`npool = {1}" -f $app.PhysicalPath, $app.applicationPool) }
else { Line 'FAIL' "Application '/$AppAlias' under '$ParentSite' NOT found" '' 'run deploy.bat in application mode (iis-site step).' }

# --- 4. HTTPS binding + cert ---------------------------------------------
Head 'HTTPS binding + certificate'
$bindWanted = "*:$($HttpsPort):$Hostname"
$httpsB = Get-WebBinding -Name $ParentSite -Protocol https -ErrorAction SilentlyContinue
$match = $httpsB | Where-Object { $_.bindingInformation -eq $bindWanted }
Line ($(if($match){'PASS'}else{'FAIL'})) "https binding $bindWanted present" (($httpsB | ForEach-Object { "$($_.bindingInformation)  sslFlags=$($_.sslFlags)" }) -join "`n") 'run deploy.bat with EnableHttps=true, or add the binding manually.'
$ssl = netsh http show sslcert 2>$null | Out-String
if ($ssl -match ":$HttpsPort\b") {
    $block = ($ssl -split "`r?`n" | Select-String -Pattern 'Hostname|IP:port|Certificate Hash|Application ID' | Select-Object -First 8) -join "`n"
    Line 'INFO' 'HTTP.SYS SSL cert bindings (relevant lines)' $block
} else { Line 'WARN' 'No SSL cert binding found in HTTP.SYS for this port' 'the cert may not be attached to the binding' 'Re-run the https-binding step or attach the cert via AddSslCertificate.' }
# bound cert expiry
$hash = [regex]::Match($ssl, "0\.0\.0\.0:$HttpsPort\s*\r?\n\s*Certificate Hash\s*:\s*([0-9a-fA-F]+)")
if ($hash.Success) {
    $thumb = $hash.Groups[1].Value.Trim()
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $thumb }
    if ($cert) {
        $days = [int]($cert.NotAfter - (Get-Date)).TotalDays
        Line ($(if($days -gt 0){'PASS'}else{'FAIL'})) "bound cert expires $($cert.NotAfter) ($days days)" "subject=$($cert.Subject)" $(if($days -le 0){'the bound certificate is EXPIRED - bind a valid cert.'})
    }
}

# --- 5. Network listener --------------------------------------------------
Head 'Network listener'
$lsn = Get-NetTCPConnection -LocalPort $HttpsPort -State Listen -ErrorAction SilentlyContinue
Line ($(if($lsn){'PASS'}else{'FAIL'})) "Something is listening on :$HttpsPort" (($lsn | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" } | Select-Object -Unique) -join '  ') 'ensure the site/binding is started and port 443 is not blocked.'

# --- 6. Database reachability (from app\.env) -----------------------------
Head 'Database (from app\.env)'
if (Test-Path $envFile) {
    $envLines = Get-Content $envFile
    function EnvVal([string]$k) { ($envLines | Where-Object { $_ -match "^\s*$k\s*=" } | Select-Object -First 1) -replace "^\s*$k\s*=\s*", '' }
    $dbHost = (EnvVal 'DB_HOST').Trim()
    $dbPort = (EnvVal 'DB_PORT').Trim(); if (-not $dbPort) { $dbPort = '5432' }
    $dbName = (EnvVal 'DB_NAME').Trim()
    $dbUser = (EnvVal 'DB_USER').Trim()
    Line 'INFO' "DB_HOST=$dbHost  DB_PORT=$dbPort  DB_NAME=$dbName  DB_USER=$dbUser"
    if ($dbHost -eq 'localhost' -or $dbHost -eq '127.0.0.1') {
        Line 'WARN' 'DB_HOST is localhost' 'you said the DB is on a separate server' 'set DB_HOST to the real DB server in app\.env, then Restart-WebAppPool.'
    }
    if ($dbHost) {
        $t = Test-NetConnection -ComputerName $dbHost -Port ([int]$dbPort) -WarningAction SilentlyContinue
        Line ($(if($t.TcpTestSucceeded){'PASS'}else{'FAIL'})) "TCP $dbHost`:$dbPort reachable = $($t.TcpTestSucceeded)" '' "open firewall / verify PostgreSQL listens on $dbHost`:$dbPort and pg_hba.conf allows this server."
    }
} else { Line 'WARN' 'no app\.env - cannot check DB' }

# --- 7. The real request (MCP initialize probe, loopback, bypasses DNS) ---
# NOTE: a plain GET to an MCP streamable-http endpoint opens a long-lived SSE
# stream and never returns -> curl would hang until timeout (false failure).
# We POST a real 'initialize' request and read the status from the RESPONSE
# HEADERS (-D -), so even if the body then streams we still capture the code.
Head 'Live request through IIS (MCP initialize probe; cold start can take ~15-30s)'
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
$healthy = $false
$code = '000'
if ($curl) {
    $initBody = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"postcheck","version":"1"}}}'
    $per = [Math]::Min($RequestTimeoutSec, 40)
    for ($i=1; $i -le 2; $i++) {
        $hdr = & curl.exe -s -D - -o NUL -k $publicUrl --resolve "$Hostname`:$HttpsPort`:127.0.0.1" `
                 -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" `
                 --data $initBody --max-time $per 2>$null
        $statusLine = ($hdr | Select-String -Pattern '^HTTP/' | Select-Object -First 1)
        $sid        = ($hdr | Select-String -Pattern 'mcp-session-id' | Select-Object -First 1)
        if ($statusLine) { $code = ([regex]::Match("$statusLine", 'HTTP/\S+\s+(\d+)')).Groups[1].Value } else { $code = '000' }
        Write-Host ("  attempt {0}: HTTP {1} {2}" -f $i, $code, $(if($sid){'(mcp-session-id present)'})) -ForegroundColor DarkGray
        if ($code -match '^(200|400|405|406)$') { $healthy = $true; break }
    }
    if ($healthy) {
        Line 'PASS' "MCP endpoint alive (HTTP $code)" 'the /mcp endpoint answered the initialize handshake'
    } else {
        switch -regex ($code) {
            '404'   { Line 'FAIL' 'HTTP 404 - app reached but path wrong' '' "set web.config MCP_PATH to $mcpPath (or '/') and Restart-WebAppPool $AppPoolName." }
            '50\d'  { Line 'FAIL' "HTTP $code - IIS up but Python/HPH failed to start" '' 'read app\logs\httpplatform.log for the Python traceback.' }
            '000'   { Line 'FAIL' 'No HTTP response (connection failed or startup hang)' '' "check app\logs\httpplatform.log; run app manually: cd $ProjectRoot; .\.venv\Scripts\python.exe run_http.py" }
            default { Line 'FAIL' "Unexpected HTTP $code" '' 'inspect app\logs\httpplatform.log.' }
        }
    }
} else { Line 'WARN' 'curl.exe not found' '' 'install curl or test with Invoke-WebRequest.' }

# --- 8. HttpPlatformHandler module ---------------------------------------
Head 'HttpPlatformHandler module'
$hph = Get-WebGlobalModule | Where-Object { $_.Name -like '*httpPlatform*' }
Line ($(if($hph){'PASS'}else{'FAIL'})) 'HttpPlatformHandler module registered' $(if($hph){$hph.Name}) 'install httpplatformhandler*.msi (precheck.bat --install) - required for HPH hosting.'

# --- 9. Logs --------------------------------------------------------------
Head 'Logs (tails)'
if (Test-Path $hphLog) { Line 'INFO' "httpplatform.log (last 30) - $hphLog"; Get-Content $hphLog -Tail 30 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray } }
else { Line 'WARN' 'httpplatform.log not found' 'means HPH has not launched Python from a real request yet' }
if (Test-Path $mcpLog) { Line 'INFO' "mcp-server.log (last 12) - $mcpLog"; Get-Content $mcpLog -Tail 12 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray } }
else { Line 'WARN' 'mcp-server.log not found' }

# --- Summary --------------------------------------------------------------
Write-Host ""
Write-Host "======================= SUMMARY =======================" -ForegroundColor White
Write-Host ("FAIL: {0}    WARN: {1}" -f $script:FailCount, $script:WarnCount) -ForegroundColor $(if($script:FailCount){'Red'}elseif($script:WarnCount){'Yellow'}else{'Green'})
if ($healthy -and $script:FailCount -eq 0) {
    Write-Host "OVERALL: HEALTHY - the /mcp endpoint is live. Point your MCP client at $publicUrl" -ForegroundColor Green
} elseif ($healthy) {
    Write-Host "OVERALL: endpoint is LIVE but some checks need attention (see below)." -ForegroundColor Yellow
} else {
    Write-Host "OVERALL: endpoint NOT responding yet - follow the suggested actions." -ForegroundColor Red
}
if ($script:Suggest.Count -gt 0) {
    Write-Host ""
    Write-Host "== SUGGESTED ACTIONS ==" -ForegroundColor Cyan
    $n=0; $script:Suggest | Select-Object -Unique | ForEach-Object { $n++; Write-Host ("  {0}. {1}" -f $n, $_) -ForegroundColor White }
}
Write-Host ""
Write-Host "Note: a browser shows no page even when healthy - MCP replies 400/405/406 to a plain GET." -ForegroundColor DarkGray
Write-Host "=======================================================" -ForegroundColor White
