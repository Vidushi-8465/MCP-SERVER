@echo off
REM Create C:\inetpub\mcp and copy web.config. Run as Administrator. See §7.1.
setlocal

set "SITE=C:\inetpub\MCPserver"
set "REPO=%~dp0..\.."
set "CONFIG=%REPO%\deploy\inetpub\mcp\web.config"

if not exist "%CONFIG%" (
    echo web.config not found: %CONFIG%
    exit /b 1
)

if not exist "%SITE%" mkdir "%SITE%"
copy /Y "%CONFIG%" "%SITE%\web.config"
if errorlevel 1 goto :fail

echo Created %SITE% and copied web.config.
echo Next: add the IIS site in IIS Manager (site name: MCPserver, hostname: sitgis.jioconnect.com, path: /MCPserver).
goto :end

:fail
echo IIS site setup failed.
exit /b 1

:end
endlocal
