@echo off
REM Probe: Tier 3 refusal verification.
REM Writes a probe .as file that references a deliberately-fake asset accessor
REM (assets::CK_TIER3_PROBE_NONEXISTENT_ASSET()). The dispatcher should:
REM   1. Parse 'No matching signatures to assets::CK_TIER3_PROBE_NONEXISTENT_ASSET()'
REM   2. Classify as KickGenerator_AssetRegistry
REM   3. Scan for CK_TIER3_PROBE_NONEXISTENT_ASSET.uasset on disk
REM   4. Not find it -> hit Tier 3 refusal banner
REM
REM Expected log evidence (post-fix):
REM   "[SelfHeal] AssetRegistry stub synthesis failed for assets::CK_TIER3_PROBE_NONEXISTENT_ASSET() ..."
REM   "Tier 3 UObject fallback is disabled (would produce a parser-blind typed-conversion error ...)"
REM
REM Editor MUST be closed before running.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_probe_tier3_corrupt.ps1"
