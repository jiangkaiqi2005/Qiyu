@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0find_python_and_run.ps1" %*
exit /b %errorlevel%
