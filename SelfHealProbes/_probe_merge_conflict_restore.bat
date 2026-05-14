@echo off
REM Restore Probe A canonicals from .assetsbak / .handlebak / .entitybak.
REM Idempotent: silently skips strategies that weren't drifted.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_merge_conflict_restore.ps1"
