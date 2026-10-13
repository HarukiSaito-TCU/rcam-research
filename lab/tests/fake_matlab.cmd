@echo off
rem Fake matlab for Test-MatlabJobRunner.ps1 (same arguments as matlab.exe: -batch "<code>" -logfile "<log>").
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0fake_matlab.ps1" %*
exit /b %ERRORLEVEL%
