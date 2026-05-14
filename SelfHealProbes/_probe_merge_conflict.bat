@echo off
REM Probe A: cold-start merge-conflict simulation.
REM Drifts up to three generated files in one shot to exercise the dispatcher's
REM multi-strategy bootstrap drain (EntitySpawnParams + DynamicHandle + AssetRegistry)
REM followed by PostCompile canonical regen.
REM
REM Targets are picked at PROBE TIME from the project's Script/Generated/ state.
REM Strategies skip individually if their target data isn't available
REM (e.g. a project with no AR configs skips the AssetRegistry drift).
REM
REM Editor MUST be closed before running. After running, launch the project's
REM editor and watch Saved/Logs/<Project>*.log for self-heal events. Then run
REM `_probe_merge_conflict_restore.bat`.
REM Verify with: pwsh _probe_verify.ps1 merge_conflict
REM
REM Backups go to .assetsbak / .handlebak / .entitybak (gitignored by convention).
REM Sidecar _probe_merge_conflict.targets.json records what got drifted.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_merge_conflict.ps1"
