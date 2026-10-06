@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-collector-service.ps1" %*
pause
