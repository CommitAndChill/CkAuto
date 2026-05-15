@echo off
REM Lock-tolerance probe restore — removes the probe .as + sidecar.
REM Companion to _probe_lock_tolerance.bat / .ps1.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_lock_tolerance_restore.ps1" %*
