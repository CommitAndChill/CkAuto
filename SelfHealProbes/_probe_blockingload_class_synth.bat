@echo off
REM Probe D: BlockingLoadClass synth-flavor reproduction.
REM Editor MUST already be running. Edits a canonical *Assets.as to remove
REM one BP-class _Class accessor pair, then drops a single AS file
REM referencing assets::load::<Target>_Class() as the sole trigger.
REM
REM After running:
REM   pwsh _probe_verify.ps1 blockingload_class_synth -Tail
REM   _probe_blockingload_class_synth_restore.bat

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_blockingload_class_synth.ps1"
