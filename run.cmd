@echo off
chcp 65001 >nul
setlocal
set "PS=%~dp0SnowLuma-LoginProbe-Fix.ps1"
if not exist "%PS%" (
  echo [ERROR] SnowLuma-LoginProbe-Fix.ps1 not found next to this file.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS%" -Restart
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo Done. Refresh the WebUI page and click the probe button again.
) else (
  echo Script exit code %RC% - see the messages above.
)
pause
