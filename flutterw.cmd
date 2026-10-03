@echo off
setlocal
set "KIRAKARA_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" (
  set "KIRAKARA_POWERSHELL=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
)
if not exist "%KIRAKARA_POWERSHELL%" (
  echo Kirakara flutterw requires Windows PowerShell 5.1 or newer. 1>&2
  exit /b 1
)
"%KIRAKARA_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0flutterw.ps1" %*
exit /b %ERRORLEVEL%
