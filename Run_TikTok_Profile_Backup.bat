@echo off
setlocal
cd /d "%~dp0"

title TikTok Profile Backup

echo ================================================
echo TikTok Profile Backup
echo ================================================
echo.
echo Paste any TikTok profile link when prompted.
echo Example: https://www.tiktok.com/@username
echo.

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: Windows PowerShell was not found.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TikTok-Profile-Backup.ps1"
set "EXITCODE=%ERRORLEVEL%"

echo.
echo ================================================
if "%EXITCODE%"=="0" (
    echo Script finished successfully.
) else (
    echo Script stopped with exit code %EXITCODE%.
)
echo ================================================
echo.
echo Press any key to close this window.
pause >nul

exit /b %EXITCODE%
