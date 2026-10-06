@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-pc-memory-collector-service.ps1" %*
pause
