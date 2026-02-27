@echo off
set "SCRIPT_DIR=%~dp0"
start http://localhost:8080/
powershell -Optimization -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_DIR%..\scripts\securepaq-gui.ps1"
