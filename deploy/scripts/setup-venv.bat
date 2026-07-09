@echo off
REM Create venv and install dependencies. See docs/DEPLOYMENT_IIS_WINDOWS_SERVER.md §4.2.
setlocal
cd /d "%~dp0..\.."

if not exist .venv (
    echo Creating virtual environment...
    python -m venv .venv
    if errorlevel 1 goto :fail
)

call .venv\Scripts\activate.bat
if errorlevel 1 goto :fail

python -m pip install --upgrade pip
pip install -r requirements.txt
pip install -r deploy\requirements-http.txt
if errorlevel 1 goto :fail

echo.
echo Virtual environment ready at %CD%\.venv
goto :end

:fail
echo Setup failed.
exit /b 1

:end
endlocal
