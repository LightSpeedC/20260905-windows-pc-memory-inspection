@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-pc-memory-collector.ps1" %*
pause
