@echo off
REM Probe E: WBP _Class soft-class synth-resolution reproduction.
REM Editor MUST already be running. Edits a canonical *Assets.as to remove
REM one WBP _Class accessor (TSoftClassPtr<X>) plus its blocking sibling,
REM then drops a single AS file referencing assets::<Target>_WBP_Class() as
REM the sole trigger.
REM
REM Targets the Tier 2.5 AssetData NativeParentClass tag fallback that
REM resolves WBPs whose ParentClass is an AS-defined UClass (LoadObject
REM can't construct those during AS-compile failure).
REM
REM After running:
REM   pwsh _probe_verify.ps1 wbp_class_synth -Tail
REM   _probe_wbp_class_synth_restore.bat

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_wbp_class_synth.ps1"
