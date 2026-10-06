@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-collector.ps1" %*
pause
