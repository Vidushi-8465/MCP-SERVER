@echo off
REM ==========================================================================
REM  run-tests.bat  -  Unit tests for the HPH deploy tooling.
REM  Self-contained (Windows PowerShell 5.1 only; no Pester, no internet).
REM  Exit code: 0 = all pass, 1 = one or more failures.
REM ==========================================================================
setlocal
set "DEPLOY_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%DEPLOY_DIR%tests\DeployHph.Tests.ps1"
exit /b %ERRORLEVEL%
