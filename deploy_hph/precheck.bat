@echo off
REM ==========================================================================
REM  precheck.bat  (HttpPlatformHandler mode)
REM
REM  Verifies EVERYTHING needed to run the MCP server on IIS via
REM  HttpPlatformHandler, and can also INSTALL the missing software from the
REM  offline bundle (apps-py-iis), one by one, silently -- then re-verifies.
REM
REM  Checks:
REM    [OS]       Administrator rights, Windows OS
REM    [IIS]      IIS Web-Server role, (WebSockets), (Windows Auth),
REM               HttpPlatformHandler module
REM    [Runtime]  Python >= 3.10 (64-bit), pip
REM    [App]      Project source present (app\server.py, requirements.txt)
REM    [Database] PostgreSQL port reachable (if a remote DbHost is configured)
REM
REM  Bundle installers recognised (HPH mode):
REM    VC_redist*.exe            -> /install /quiet /norestart
REM    python-*.exe             -> /quiet InstallAllUsers=1 PrependPath=1
REM    httpplatformhandler*.msi -> msiexec /i ... /qn /norestart
REM    *.whl                    -> left for pip (used during deploy)
REM  (URL Rewrite / ARR / NSSM are NOT needed and are ignored.)
REM
REM  Usage:
REM    precheck.bat                     verify only (read-only)
REM    precheck.bat --install           install from bundle, then verify (Admin)
REM    precheck.bat --install --dry-run preview the install plan, change NOTHING
REM
REM  Exit code: 0 = all REQUIRED prerequisites present, 1 = missing.
REM ==========================================================================
setlocal EnableDelayedExpansion
set "DEPLOY_DIR=%~dp0"
set "PSARGS="
:parse
if "%~1"=="" goto run
if /I "%~1"=="--install" (set "PSARGS=!PSARGS! -Install") ^
else if /I "%~1"=="-install" (set "PSARGS=!PSARGS! -Install") ^
else if /I "%~1"=="--dry-run" (set "PSARGS=!PSARGS! -DryRun") ^
else if /I "%~1"=="/dryrun" (set "PSARGS=!PSARGS! -DryRun") ^
else if /I "%~1"=="-dryrun" (set "PSARGS=!PSARGS! -DryRun") ^
else set "PSARGS=!PSARGS! %~1"
shift
goto parse
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%DEPLOY_DIR%lib\drivers\Run-Precheck.ps1" !PSARGS!
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo [precheck] RESULT: OK) else (echo [precheck] RESULT: MISSING PREREQUISITES ^(exit %RC%^))
exit /b %RC%
