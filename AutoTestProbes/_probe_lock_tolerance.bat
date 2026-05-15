@echo off
REM Lock-tolerance probe — drops a UCk_AutoTest_Base subclass at runtime to
REM verify the populator's OFPA-aware save path leaves the .umap byte-
REM identical on disk after a routine test add.
REM
REM Editor MUST already be running.
REM
REM REQUIRED PARAMETER: -MapPath <path-to-target-.umap>
REM OPTIONAL:           -TestSourceDir <path-to-AS-watched-dir>
REM
REM After running:
REM   pwsh CkAuto\AutoTestProbes\_probe_verify.ps1
REM   CkAuto\AutoTestProbes\_probe_lock_tolerance_restore.bat

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_lock_tolerance.ps1" %*
