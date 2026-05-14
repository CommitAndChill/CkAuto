@echo off
REM Probe B: mid-session add-and-run simulation.
REM Editor MUST already be running. Drops a single new AS file that
REM references three unresolved symbols in ONE save event so the mid-session
REM ticker drain hits all three strategies.
REM
REM Targets (asset stem, class name, handle type) are picked at PROBE TIME.
REM Sidecar _probe_mid_session_add.targets.json records the picks so the
REM verifier can build dynamic regexes.
REM
REM After running:
REM   pwsh _probe_verify.ps1 mid_session_add
REM   _probe_mid_session_add_restore.bat

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_mid_session_add.ps1"
