@echo off
setlocal
for %%I in ("%~dp0..") do set "PROJECT_DIR=%%~fI"
set "EXE=%PROJECT_DIR%\build\windows\x64\runner\Release\kirakara_app.exe"

cd /d "%PROJECT_DIR%"
echo Building Kirakara-App Release exe...
echo.
call "%PROJECT_DIR%\flutterw.cmd" build windows
if errorlevel 1 goto failed
if not exist "%EXE%" goto failed

echo.
echo Release exe built:
echo %EXE%
explorer.exe /select,"%EXE%"
pause
exit /b 0

:failed
echo.
echo Build failed. The console output above has the useful error.
pause
exit /b 1
