@echo off
REM Restore Probe B by deleting the probe .as and sidecar. Idempotent.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_mid_session_add_restore.ps1"
