@echo off
setlocal
for %%I in ("%~dp0..") do set "PROJECT_DIR=%%~fI"

cd /d "%PROJECT_DIR%"
echo Starting Kirakara-App with Flutter debug runner...
echo.
call "%PROJECT_DIR%\flutterw.cmd" run -d windows
set "RUN_EXIT_CODE=%ERRORLEVEL%"

echo.
echo Debug runner exited.
pause
exit /b %RUN_EXIT_CODE%
