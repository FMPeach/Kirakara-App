@echo off
setlocal
for %%I in ("%~dp0..") do set "PROJECT_DIR=%%~fI"
set "EXE=%PROJECT_DIR%\build\windows\x64\runner\Debug\kirakara_app.exe"

cd /d "%PROJECT_DIR%"
echo Building Kirakara-App Debug exe...
echo.
call "%PROJECT_DIR%\flutterw.cmd" build windows --debug
if errorlevel 1 goto failed
if not exist "%EXE%" goto failed

echo.
echo Debug exe built:
echo %EXE%
explorer.exe /select,"%EXE%"
pause
exit /b 0

:failed
echo.
echo Build failed. The console output above has the useful error.
pause
exit /b 1
