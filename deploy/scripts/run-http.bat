@echo off
REM Smoke-test the HTTP entry point. See docs/DEPLOYMENT_IIS_WINDOWS_SERVER.md §5.
setlocal
cd /d "%~dp0..\.."

if not exist .venv\Scripts\python.exe (
    echo Run deploy\scripts\setup-venv.bat first.
    exit /b 1
)

call .venv\Scripts\activate.bat
python run_http.py
