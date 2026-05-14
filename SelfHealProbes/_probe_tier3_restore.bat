@echo off
REM Restore for _probe_tier3_corrupt.bat — deletes the probe .as file.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_tier3_restore.ps1"
