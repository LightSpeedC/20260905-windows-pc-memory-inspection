@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fill-task-xml-template.ps1" %*
pause
