@echo off
setlocal
for %%I in ("%~dp0..") do set "PROJECT_DIR=%%~fI"
set "BUNDLE=%PROJECT_DIR%\build\windows\x64\runner\Debug"
set "EXE=%PROJECT_DIR%\build\windows\x64\runner\Debug\kirakara_app.exe"

cd /d "%PROJECT_DIR%"
echo Verifying the repository-local Engine and Debug app bundle...
call "%PROJECT_DIR%\flutterw.cmd" build windows --debug
if errorlevel 1 goto failed
if not exist "%EXE%" goto failed

echo Starting:
echo %EXE%
start "" /d "%BUNDLE%" "%EXE%"
exit /b 0

:failed
echo.
echo Debug build failed. The console output above has the useful error.
pause
exit /b 1
