@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-check-task.ps1" %*
pause
