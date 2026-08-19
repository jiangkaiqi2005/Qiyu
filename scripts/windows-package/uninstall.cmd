@echo off
set "QIYU_UNINSTALL_SCRIPT=%~dp0Uninstall-Qiyu.ps1"
cd /d "%TEMP%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%QIYU_UNINSTALL_SCRIPT%" %*
exit /b %ERRORLEVEL%
