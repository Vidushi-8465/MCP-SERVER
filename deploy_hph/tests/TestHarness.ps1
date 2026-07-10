<#
    TestHarness.ps1 — tiny, self-contained test framework (no Pester, no internet).
    Runs on the built-in Windows PowerShell 5.1 on any VM.
#>

$script:TestTotal   = 0
$script:TestFailed  = 0
$script:TestFailures = New-Object System.Collections.ArrayList

function Describe {
    param([string]$Name, [scriptblock]$Body)
    Write-Host ""
    Write-Host "== $Name ==" -ForegroundColor Cyan
    & $Body
}

function It {
    param([string]$Name, [scriptblock]$Body)
    $script:TestTotal++
    try {
        & $Body
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    }
    catch {
        $script:TestFailed++
        [void]$script:TestFailures.Add("$Name -> $($_.Exception.Message)")
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -ne $Actual) { throw "Expected <$Expected> but got <$Actual>. $Message" }
}
function Assert-True     { param($Condition, [string]$Message = '') if (-not $Condition) { throw "Expected TRUE. $Message" } }
function Assert-False    { param($Condition, [string]$Message = '') if ($Condition) { throw "Expected FALSE. $Message" } }
function Assert-Contains { param($Collection, $Item, [string]$Message = '') if ($Collection -notcontains $Item) { throw "Expected collection to contain <$Item>. $Message" } }
function Assert-NotContains { param($Collection, $Item, [string]$Message = '') if ($Collection -contains $Item) { throw "Expected collection NOT to contain <$Item>. $Message" } }
function Assert-Match    { param([string]$Text, [string]$Pattern, [string]$Message = '') if ($Text -notmatch $Pattern) { throw "Expected <$Text> to match /$Pattern/. $Message" } }
function Assert-NotNull  { param($Value, [string]$Message = '') if ($null -eq $Value) { throw "Expected non-null. $Message" } }
function Assert-Throws   { param([scriptblock]$Body, [string]$Message = '') $t=$false; try { & $Body } catch { $t=$true }; if (-not $t) { throw "Expected an exception. $Message" } }

function Invoke-TestSummary {
    Write-Host ""
    Write-Host "-------------------------------------------" -ForegroundColor DarkGray
    if ($script:TestFailed -gt 0) {
        Write-Host "RESULT: FAILED  (Total: $script:TestTotal, Failed: $script:TestFailed)" -ForegroundColor Red
        foreach ($f in $script:TestFailures) { Write-Host "  - $f" -ForegroundColor Red }
        exit 1
    } else {
        Write-Host "RESULT: PASSED  (Total: $script:TestTotal, Failed: 0)" -ForegroundColor Green
        exit 0
    }
}
