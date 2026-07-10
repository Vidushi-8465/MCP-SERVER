@echo off
REM ==========================================================================
REM  deploy.bat  (HttpPlatformHandler mode)
REM
REM  Automated end-to-end deployment of the MCP server to IIS using
REM  HttpPlatformHandler (IIS launches and manages the Python process; NO ARR,
REM  NO URL Rewrite, NO NSSM). Reads config\deploy.settings.ps1.
REM
REM  Steps (see lib\DeployHph.psm1 -> New-DeployPlan):
REM    01 copy run_http.py to project root      06 create IIS application pool
REM    02 create Python virtual environment     07 create IIS site (-> app dir)
REM    03 pip install deps + uvicorn/starlette   08 write HPH web.config
REM    04 write app\.env                        09 add firewall rules (80/443)
REM    05 smoke-test the app boots              10 start app pool + site
REM
REM  A real run first runs the prerequisite check and aborts if anything
REM  REQUIRED is missing. Requires Administrator (except with --dry-run).
REM
REM  Usage:
REM    deploy.bat --dry-run     preview the full plan, change NOTHING   <-- first
REM    deploy.bat               perform the deployment
REM ==========================================================================
setlocal EnableDelayedExpansion
set "DEPLOY_DIR=%~dp0"
set "PSARGS="
:parse
if "%~1"=="" goto run
if /I "%~1"=="--dry-run" (set "PSARGS=!PSARGS! -DryRun") ^
else if /I "%~1"=="/dryrun" (set "PSARGS=!PSARGS! -DryRun") ^
else if /I "%~1"=="-dryrun" (set "PSARGS=!PSARGS! -DryRun") ^
else set "PSARGS=!PSARGS! %~1"
shift
goto parse
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%DEPLOY_DIR%lib\drivers\Run-Deploy.ps1" !PSARGS!
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo [deploy] RESULT: OK) else (echo [deploy] RESULT: FAILED ^(exit %RC%^))
exit /b %RC%
