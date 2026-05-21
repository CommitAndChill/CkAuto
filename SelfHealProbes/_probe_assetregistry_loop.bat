@echo off
REM Probe C: AssetRegistry stub-deletion-loop reproduction.
REM Editor MUST already be running. Drops a single new AS file that
REM references ONE unresolved asset accessor — the minimal trigger for
REM the post-2026-05-21 self-heal PostCompile-ordering bug.
REM
REM After running:
REM   pwsh _probe_verify.ps1 assetregistry_loop -Tail
REM   _probe_assetregistry_loop_restore.bat

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_assetregistry_loop.ps1"
