#requires -Version 7
<#
.SYNOPSIS
    Verifies AS self-heal integration probe outcomes by grepping the editor
    log for expected dispatcher events.

.DESCRIPTION
    Project-agnostic: project name and root are resolved from script
    location ($PSScriptRoot/../..). Expected event lists are built dynamically
    from sidecar files (where applicable) so events for skipped strategies
    are dropped automatically.

    Exit codes:
      0 — all events matched (PROBE PASSED)
      1 — at least one event missing (PROBE FAILED)
      2 — missing args / sidecar / log / project root (usage error)

.PARAMETER Probe
    Which probe to verify:
      merge_conflict      — cold-start bootstrap drain (multi-strategy)
      mid_session_add     — mid-session ticker drain (multi-strategy)
      tier3               — Tier 3 refusal banner (no sidecar — fixed events)
      assetregistry_loop  — verifies AR-sibling deletion happens AFTER the
                            regen ticker rewrites the canonical (post-fix)
                            rather than BEFORE (pre-fix). See the Probe C
                            row in README.md.
      blockingload_class_synth — verifies the synthesizer classifies
                            `assets::load::<X>_Class()` as BlockingLoadClass
                            (strips `_Class` for disk lookup, emits a
                            TSubclassOf<X> stub that compiles). See the
                            Probe D row in README.md.
      wbp_class_synth     — verifies the Tier 2.5 AssetData
                            NativeParentClass tag fallback resolves WBP
                            `_Class` accessors whose ParentClass is an
                            AS-defined UClass (LoadObject can't construct
                            those at modal-tick). See the Probe E row in
                            README.md.

.PARAMETER LogPath
    Optional explicit log path. If omitted, the newest
    Saved/Logs/<ProjectName>*.log by LastWriteTime is used. Useful when the
    editor was launched with -ABSLOG=<custom>.

.PARAMETER Tail
    Live-tail mode: scan existing log content for already-fired events, then
    follow the log file for new lines and match the remaining events as they
    arrive. Useful for "launch editor, run verifier in another shell, watch
    recovery unfold". Exits when all events match or you Ctrl+C.

.EXAMPLE
    pwsh _probe_verify.ps1 merge_conflict
    pwsh _probe_verify.ps1 mid_session_add -LogPath Saved/Logs/probe_b.log
    pwsh _probe_verify.ps1 tier3
    pwsh _probe_verify.ps1 mid_session_add -Tail
#>
Param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('merge_conflict', 'mid_session_add', 'tier3', 'assetregistry_loop', 'blockingload_class_synth', 'wbp_class_synth')]
    [string]$Probe,

    [string]$LogPath,

    [switch]$Tail
)

$ErrorActionPreference = 'Stop'

# ---- Resolve project root + name from script location ----
$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$uproject = Get-ChildItem -Path $projectRoot -Filter '*.uproject' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $uproject) { Write-Error "No .uproject found at $projectRoot."; exit 2 }
$projectName = [System.IO.Path]::GetFileNameWithoutExtension($uproject.Name)

# ---- Resolve log file ----
if (-not $LogPath) {
    $logDir = Join-Path $projectRoot 'Saved\Logs'
    if (-not (Test-Path $logDir)) { Write-Error "No Saved/Logs directory at $logDir"; exit 2 }
    $newest = Get-ChildItem -Path $logDir -Filter "$projectName*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $newest) { Write-Error "No $projectName*.log files in $logDir"; exit 2 }
    $LogPath = $newest.FullName
}
if (-not (Test-Path $LogPath)) { Write-Error "Log not found: $LogPath"; exit 2 }
Write-Host "Project: $projectName" -ForegroundColor Cyan
Write-Host "Verifying against log: $LogPath" -ForegroundColor Cyan

# ---- Event factory ----
function New-Event {
    Param([string]$Description, [string]$Pattern, [switch]$Anywhere)
    [PSCustomObject]@{ Description = $Description; Pattern = $Pattern; Anywhere = [bool]$Anywhere }
}

# ---- Build event list (dynamic, sidecar-driven) ----
$events = @()

if ($Probe -eq 'merge_conflict') {
    $sidecarPath = Join-Path $projectRoot 'Script\Generated\_probe_merge_conflict.targets.json'
    if (-not (Test-Path $sidecarPath)) {
        Write-Error "Sidecar not found: $sidecarPath. Run _probe_merge_conflict.bat first."
        exit 2
    }
    $sc = Get-Content $sidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $drifts = $sc.Drifts
    $strategyCount = if ($drifts) { ($drifts | Get-Member -MemberType NoteProperty | Measure-Object).Count } else { 0 }
    Write-Host "Sidecar: $strategyCount strategy/strategies drifted" -ForegroundColor DarkCyan
    Write-Host ''

    if ($strategyCount -eq 0) {
        Write-Host 'No drifts recorded in sidecar — this project has nothing the probe could drift.' -ForegroundColor Yellow
        Write-Host 'VERDICT: PROBE PASSED (no-op).' -ForegroundColor Green
        exit 0
    }

    $events += New-Event 'OnReloadHadErrors fired (bootstrap mode)' 'OnReloadHadErrors fired \(bootstrap mode, cycle \d+ of 3\)\. Parsed \d+ actionable roots' -Anywhere
    $events += New-Event 'Queued recovery action(s) for bootstrap modal-tick apply' 'Queued \d+ recovery action\(s\) for bootstrap modal-tick apply' -Anywhere
    $events += New-Event 'Modal-tick deferred apply firing — draining N pending action(s)' 'Modal-tick deferred apply firing — draining \d+ pending action\(s\)' -Anywhere

    # Per-strategy stub-synthesis events. Anywhere-search because the dispatcher
    # emits them in classifier-iteration order which varies, and strategies may
    # re-fire across multiple cycles (semantic check is "did this happen?").
    if ($drifts.DynamicHandle) {
        $h = [regex]::Escape($drifts.DynamicHandle.TypeName)
        $events += New-Event "DynamicHandle: synthesized JSON stub entry for '$($drifts.DynamicHandle.TypeName)'" `
                            "DynamicHandle: synthesized JSON stub entry for '$h'" -Anywhere
    }
    if ($drifts.EntitySpawnParams) {
        $n = [regex]::Escape($drifts.EntitySpawnParams.Namespace)
        $events += New-Event "Synthesized stub for $($drifts.EntitySpawnParams.Namespace)::Params" `
                            "Synthesized stub for $n::Params" -Anywhere
    }
    if ($drifts.AssetRegistry) {
        $a = [regex]::Escape($drifts.AssetRegistry.Accessor)
        $events += New-Event "Synthesized AssetRegistry stub for assets::$($drifts.AssetRegistry.Accessor)" `
                            "Synthesized AssetRegistry stub for assets::$a" -Anywhere
    }

    $events += New-Event 'Cycle N applied N strategy/strategies (bootstrap)' 'Cycle \d+ applied \d+ strategy/strategies\. Hot-reload' -Anywhere

    if ($drifts.DynamicHandle) {
        $events += New-Event 'DynamicHandle deferred regen fired (PostCompile sibling-detect OR OnPostEngineInit deferred)' `
                            '(PostCompile detected pending _StubRecovery_DynamicHandleTypes\.json sibling|Deferred DynamicHandle JSON regen firing)' `
                            -Anywhere
    }
    if ($drifts.AssetRegistry) {
        $events += New-Event 'PostCompile settled (shader idle AND AR idle) — AssetRegistry regen firing' `
                            'PostCompile settled \(shader compiler idle AND AR idle\) after \d+ polls' -Anywhere
    }
    $events += New-Event 'Self-heal stub file served its purpose — deleting:' 'Self-heal stub file served its purpose — deleting:' -Anywhere
}
elseif ($Probe -eq 'mid_session_add') {
    $sidecarPath = Join-Path $projectRoot 'Script\_probe_mid_session_add.targets.json'
    if (-not (Test-Path $sidecarPath)) {
        Write-Error "Sidecar not found: $sidecarPath. Run _probe_mid_session_add.bat first."
        exit 2
    }
    $sc = Get-Content $sidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "Sidecar targets: Asset=$(if ($sc.AssetName) { $sc.AssetName } else { '(none)' }), Class=$($sc.ClassName), Handle=$($sc.HandleTypeName)" -ForegroundColor DarkCyan
    Write-Host ''

    $classEsc  = [regex]::Escape($sc.ClassName)
    $handleEsc = [regex]::Escape($sc.HandleTypeName)

    $events += New-Event 'OnReloadHadErrors fired (mid-session mode)' 'OnReloadHadErrors fired \(mid-session mode, cycle \d+ of 3\)\. Parsed \d+ actionable roots' -Anywhere
    $events += New-Event 'Queued recovery action(s) for mid-session ticker apply' 'Queued \d+ recovery action\(s\) for mid-session ticker apply' -Anywhere
    $events += New-Event 'Mid-session ticker firing — draining N pending action(s)' 'Mid-session ticker firing — draining \d+ pending action\(s\)' -Anywhere

    $events += New-Event "DynamicHandle: synthesized JSON stub entry for '$($sc.HandleTypeName)'" `
                        "DynamicHandle: synthesized JSON stub entry for '$handleEsc'" -Anywhere
    $events += New-Event "Synthesized stub for $($sc.ClassName)::Params" `
                        "Synthesized stub for $classEsc::Params" -Anywhere
    if ($sc.AssetName) {
        $assetEsc = [regex]::Escape($sc.AssetName)
        $events += New-Event "Synthesized AssetRegistry stub for assets::$($sc.AssetName)" `
                            "Synthesized AssetRegistry stub for assets::$assetEsc" -Anywhere
    }

    $events += New-Event 'Cycle N applied N strategy/strategies (mid-session)' 'Cycle \d+ applied \d+ strategy/strategies \(mid-session\)' -Anywhere
    $events += New-Event 'DynamicHandle deferred regen fired (PostCompile sibling-detect OR OnPostEngineInit deferred)' `
                        '(PostCompile detected pending _StubRecovery_DynamicHandleTypes\.json sibling|Deferred DynamicHandle JSON regen firing)' `
                        -Anywhere
    if ($sc.AssetName) {
        $events += New-Event 'PostCompile settled (shader idle AND AR idle) — AssetRegistry regen firing' `
                            'PostCompile settled \(shader compiler idle AND AR idle\) after \d+ polls' -Anywhere
    }
    $events += New-Event 'Self-heal stub file served its purpose — deleting:' 'Self-heal stub file served its purpose — deleting:' -Anywhere
}
elseif ($Probe -eq 'assetregistry_loop') {
    # Probe C — positive events here; the load-bearing ordering check runs
    # in Phase 4 below.
    $sidecarPath = Join-Path $projectRoot 'Script\_probe_assetregistry_loop.targets.json'
    if (-not (Test-Path $sidecarPath)) {
        Write-Error "Sidecar not found: $sidecarPath. Run _probe_assetregistry_loop.bat first."
        exit 2
    }
    $sc = Get-Content $sidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "Sidecar target: Asset=$($sc.AssetName)" -ForegroundColor DarkCyan
    Write-Host ''

    $assetEsc = [regex]::Escape($sc.AssetName)

    # Positive — these MUST fire at least once. Ordering check is Phase 4.
    $events += New-Event "Synthesized AssetRegistry stub for assets::$($sc.AssetName)" `
                        "Synthesized AssetRegistry stub for assets::$assetEsc" -Anywhere
    $events += New-Event 'Asset Registry generation completed' `
                        'Asset Registry generation completed: \d+ succeeded, \d+ failed' -Anywhere
}
elseif ($Probe -eq 'blockingload_class_synth') {
    # Probe D — pins that `assets::load::<X>_Class()` synth emits a compilable
    # stub. Phase 5 below asserts the pre-fix `_Class.uasset not found` line is
    # absent.
    $sidecarPath = Join-Path $projectRoot 'Script\_probe_blockingload_class_synth.targets.json'
    if (-not (Test-Path $sidecarPath)) {
        Write-Error "Sidecar not found: $sidecarPath. Run _probe_blockingload_class_synth.bat first."
        exit 2
    }
    $sc = Get-Content $sidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "Sidecar: $($sc.Namespace)::$($sc.AccessorName)_Class() -> TSubclassOf<$($sc.AssetClassName)>" -ForegroundColor DarkCyan
    Write-Host ''

    $accessorEsc  = [regex]::Escape($sc.AccessorName)
    $nsEsc        = [regex]::Escape($sc.Namespace)
    $assetTypeEsc = [regex]::Escape($sc.AssetClassName)

    # GREEN log line reports the resolved class as a BARE identifier — the
    # TSubclassOf<> wrapper lives in the emitted stub body, not the log
    # message. Anywhere-search.
    $events += New-Event "Synthesized AssetRegistry stub for $($sc.Namespace)::$($sc.AccessorName)_Class() (return type $($sc.AssetClassName))" `
                        "Synthesized AssetRegistry stub for ${nsEsc}::${accessorEsc}_Class\(\) \(return type $assetTypeEsc" `
                        -Anywhere
}
elseif ($Probe -eq 'wbp_class_synth') {
    # Probe E - pins that `assets::<X>_WBP_Class()` resolves via the Tier 2.5
    # AssetData NativeParentClass tag path when LoadObject can't construct the
    # WBP (e.g. AS-defined parent class isn't registered yet). Positive: the
    # dispatcher's "Synthesized AssetRegistry stub" success line. RED-absence
    # (Phase 6 below) asserts the pre-fix "Could not resolve UClass" message
    # is absent.
    $sidecarPath = Join-Path $projectRoot 'Script\_probe_wbp_class_synth.targets.json'
    if (-not (Test-Path $sidecarPath)) {
        Write-Error "Sidecar not found: $sidecarPath. Run _probe_wbp_class_synth.bat first."
        exit 2
    }
    $sc = Get-Content $sidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "Sidecar: assets::$($sc.AccessorName)_Class() -> TSoftClassPtr<$($sc.AssetClassName)>" -ForegroundColor DarkCyan
    Write-Host ''

    $accessorEsc = [regex]::Escape($sc.AccessorName)

    # GREEN: dispatcher success log. Format (from Dispatcher.cpp ~341):
    #   `[SelfHeal] Synthesized AssetRegistry stub for assets::<Name>_Class()`
    # The bare-class return-type token in the log varies (the dispatcher
    # prints ResolvedAssetClass, which is the native parent name like
    # `UUserWidget`), so the match key is the namespace+accessor pair — that
    # alone proves the synth path completed (which it couldn't before this
    # fix because ClassName was empty and the path bailed at the Tier 3
    # refusal banner).
    $events += New-Event "Synthesized AssetRegistry stub for assets::$($sc.AccessorName)_Class()" `
                        "Synthesized AssetRegistry stub for assets::${accessorEsc}_Class\(\)" `
                        -Anywhere

    # Phase 6 regression check (below) asserts the RED signature is ABSENT.
}
elseif ($Probe -eq 'tier3') {
    # Tier 3 refusal probe — fixed events (no sidecar; the probe injects a
    # fake asset name that's the same every run).
    Write-Host 'Tier 3 refusal probe — checking for the actionable banner.' -ForegroundColor DarkCyan
    Write-Host ''

    $events += New-Event 'OnReloadHadErrors fired (any mode)' 'OnReloadHadErrors fired \((bootstrap|mid-session) mode' -Anywhere
    $events += New-Event 'AR synthesis failure for the fake asset (Tier 1/2 failed)' `
                        'AssetRegistry stub synthesis failed for assets::CK_TIER3_PROBE_NONEXISTENT_ASSET' -Anywhere
    $events += New-Event 'Tier 3 UObject fallback explicitly disabled (refusal banner)' `
                        'Tier 3 UObject fallback is disabled' -Anywhere
}

# ---- Walk log ----
$timestampRe = [regex]'\[(\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}:\d+)\]'

function Try-MatchLine {
    Param([string]$Line, [ref]$Passes, $Remaining)
    # Match $Line against EVERY unmatched event in $Remaining — a single log
    # line can satisfy multiple events (e.g. the dispatcher's Tier 3 refusal
    # writes both the "synthesis failed" and "Tier 3 ... disabled" text on
    # the same line). Returns the new remaining list.
    $matched = @()
    foreach ($evt in $Remaining) {
        if ($Line -match $evt.Pattern) {
            $tsMatch = $timestampRe.Match($Line)
            $ts = if ($tsMatch.Success) { $tsMatch.Groups[1].Value } else { '?' }
            $mode = if ($evt.Anywhere) { ' (anywhere)' } else { '' }
            Write-Host ("[PASS] @ {0} — {1}{2}" -f $ts, $evt.Description, $mode) -ForegroundColor Green
            $Passes.Value++
            $matched += $evt
        }
    }
    if ($matched.Count -eq 0) { return $Remaining }
    return @($Remaining | Where-Object { $matched -notcontains $_ })
}

$remaining = @($events)
$passes = 0

# Phase 1: scan existing log content.
$lines = Get-Content -LiteralPath $LogPath -Encoding UTF8
foreach ($line in $lines) {
    if ($remaining.Count -eq 0) { break }
    $remaining = Try-MatchLine -Line $line -Passes ([ref]$passes) -Remaining $remaining
}

# Phase 2: if -Tail and events remain, follow the file.
if ($Tail -and $remaining.Count -gt 0) {
    Write-Host ''
    Write-Host ("Live-tailing {0} for {1} remaining event(s). Ctrl+C to stop." -f $LogPath, $remaining.Count) -ForegroundColor DarkCyan
    Write-Host ''
    Get-Content -LiteralPath $LogPath -Encoding UTF8 -Wait -Tail 0 | ForEach-Object {
        if ($remaining.Count -eq 0) { break }
        $remaining = Try-MatchLine -Line $_ -Passes ([ref]$passes) -Remaining $remaining
        if ($remaining.Count -eq 0) {
            Write-Host ''
            Write-Host 'All events matched — stopping tail.' -ForegroundColor DarkCyan
        }
    }
}

# Phase 3: report unmatched events.
foreach ($evt in $remaining) {
    Write-Host ("[FAIL] — Expected: {0} (pattern: /{1}/ not found{2})" -f $evt.Description, $evt.Pattern, $(if ($Tail) { ' — tail interrupted before fire' } else { '' })) -ForegroundColor Red
}

# Phase 4: assetregistry_loop — for each AR-stub deletion, was the most
# recent preceding event a 'Queueing deferred GenerateAllAssetRegistries'
# (BUG — deletion races the deferred ticker) or an 'Asset Registry
# generation completed' (FIX — deletion happens after regen actually ran)?
# Mid-session cycle counts are intentionally NOT used here; they conflate
# this bug with orthogonal issues (asset class excluded from canonical etc.).
$loopAssertionPassed = $true
if ($Probe -eq 'assetregistry_loop') {
    $finalLines = Get-Content -LiteralPath $LogPath -Encoding UTF8
    $arDeleteRegex     = [regex]'Self-heal stub file served its purpose — deleting:.+_StubRecovery_\w*Assets\.as'
    $regenCompleteRegex = [regex]'Asset Registry generation completed: \d+ succeeded, \d+ failed'
    $queueRegenRegex    = [regex]'Queueing deferred GenerateAllAssetRegistries'

    $deletionsAfterRegen     = 0
    $deletionsBeforeRegen    = 0
    $deletionsWithoutContext = 0
    foreach ($idx in 0..($finalLines.Count - 1)) {
        if (-not $arDeleteRegex.IsMatch($finalLines[$idx])) { continue }
        # Walk backward looking for the most recent regen-completed OR
        # queue-deferred event.
        $found = $false
        for ($j = $idx - 1; $j -ge 0; --$j) {
            if ($regenCompleteRegex.IsMatch($finalLines[$j])) { $deletionsAfterRegen++; $found = $true; break }
            if ($queueRegenRegex.IsMatch($finalLines[$j]))    { $deletionsBeforeRegen++; $found = $true; break }
        }
        if (-not $found) { $deletionsWithoutContext++ }
    }
    $totalArDeletions = $deletionsAfterRegen + $deletionsBeforeRegen + $deletionsWithoutContext

    Write-Host ""
    Write-Host ("LOOP-CHECK metrics — AR-stub deletions: total {0}, post-regen {1} (FIX SIGNAL), pre-regen-but-after-queue {2} (BUG SIGNAL), no-prior-context {3}" `
        -f $totalArDeletions, $deletionsAfterRegen, $deletionsBeforeRegen, $deletionsWithoutContext) -ForegroundColor DarkCyan

    if ($totalArDeletions -eq 0) {
        Write-Host ("[FAIL] LOOP-CHECK — no AR-stub deletion lines found; the probe didn't trigger the AR strategy (or the dispatcher didn't synthesize a stub). Verify the probe target was missing from canonical *Assets.as.") -ForegroundColor Red
        $loopAssertionPassed = $false
    }
    elseif ($deletionsBeforeRegen -gt 0) {
        Write-Host ("[FAIL] LOOP-CHECK — {0} AR-stub deletion(s) fired BEFORE the matching regen completed. The synchronous deletion in PostCompile is racing the deferred FTSTicker (pre-fix ordering)." -f $deletionsBeforeRegen) -ForegroundColor Red
        $loopAssertionPassed = $false
    }
    else {
        Write-Host ("[PASS] LOOP-CHECK — every AR-stub deletion ({0}) fired AFTER its regen completed. AR cleanup is owned by the ticker callback." -f $deletionsAfterRegen) -ForegroundColor Green
    }
}

# Phase 5: blockingload_class_synth — RED signature is the literal
# `<Target>_Class.uasset' not found` (unstripped function name as disk-stem).
# Its presence proves the classifier+strip path didn't run.
$flavorAssertionPassed = $true
if ($Probe -eq 'blockingload_class_synth') {
    $sidecarPath = Join-Path $projectRoot 'Script\_probe_blockingload_class_synth.targets.json'
    if (Test-Path $sidecarPath) {
        $sc = Get-Content $sidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $accessorEsc = [regex]::Escape($sc.AccessorName)
        $redRegex = [regex]("Asset '" + $accessorEsc + "_Class\.uasset' not found under disk-converted root")
        $finalLines = Get-Content -LiteralPath $LogPath -Encoding UTF8
        $redHits = ($finalLines | Where-Object { $redRegex.IsMatch($_) }).Count

        Write-Host ""
        if ($redHits -eq 0) {
            Write-Host ("[PASS] FLAVOR-CHECK - no `Asset '$($sc.AccessorName)_Class.uasset' not found` line in log; BlockingLoadClass strip path ran.") -ForegroundColor Green
        } else {
            Write-Host ("[FAIL] FLAVOR-CHECK - found $redHits occurrence(s) of the pre-fix `Asset '$($sc.AccessorName)_Class.uasset' not found` signature. The synthesizer is NOT classifying `$($sc.Namespace)::$($sc.AccessorName)_Class()` as BlockingLoadClass; `_Class` was not stripped before disk lookup.") -ForegroundColor Red
            $flavorAssertionPassed = $false
        }
    }
}

# Phase 6: wbp_class_synth - assert the RED signature is ABSENT.
# Pre-fix failure line literally embeds the LoadObject + Tier 3 disabled
# wording when ClassName comes back empty from both resolution paths. Its
# presence proves the Tier 2.5 AssetData NativeParentClass tag fallback
# didn't run (or didn't resolve).
$wbpAssertionPassed = $true
if ($Probe -eq 'wbp_class_synth') {
    $sidecarPath = Join-Path $projectRoot 'Script\_probe_wbp_class_synth.targets.json'
    if (Test-Path $sidecarPath) {
        $sc = Get-Content $sidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $accessorEsc = [regex]::Escape($sc.AccessorName)
        # Pre-fix message text was 'Could not resolve UClass via LoadObject for
        # '<X>_Class' ...'. Post-fix message says 'via either LoadObject (Tier
        # 2) or AssetData NativeParentClass tag (Tier 2.5)'. The accessor name
        # in the message scopes the assertion to this probe's target.
        $redRegex = [regex]("Could not resolve UClass.*for '" + $accessorEsc + "_Class'")
        $finalLines = Get-Content -LiteralPath $LogPath -Encoding UTF8
        $redHits = ($finalLines | Where-Object { $redRegex.IsMatch($_) }).Count

        Write-Host ""
        if ($redHits -eq 0) {
            Write-Host ("[PASS] WBP-CHECK - no `Could not resolve UClass ... for '$($sc.AccessorName)_Class'` line in log; Tier 2.5 AssetData tag fallback resolved the native parent.") -ForegroundColor Green
        } else {
            Write-Host ("[FAIL] WBP-CHECK - found $redHits occurrence(s) of the resolution-failure signature for '$($sc.AccessorName)_Class'. The Tier 2.5 AssetData NativeParentClass tag fallback didn't fire or didn't resolve. Either the fix isn't built into the running editor, or the WBP's tag chain doesn't expose a native parent.") -ForegroundColor Red
            $wbpAssertionPassed = $false
        }
    }
}

Write-Host ''
$total = $events.Count
$allPositiveMatched = ($passes -eq $total)
$auxPassed = $loopAssertionPassed -and $flavorAssertionPassed -and $wbpAssertionPassed
if ($allPositiveMatched -and $auxPassed) {
    $suffix = ''
    if ($Probe -eq 'assetregistry_loop')          { $suffix = ' + loop-check passed' }
    elseif ($Probe -eq 'blockingload_class_synth') { $suffix = ' + flavor-check passed' }
    elseif ($Probe -eq 'wbp_class_synth')          { $suffix = ' + wbp-check passed' }
    Write-Host ("VERDICT: $passes of $total events matched$suffix. PROBE PASSED.") -ForegroundColor Green
    exit 0
}
else {
    $suffix = ''
    if ($Probe -eq 'assetregistry_loop' -and -not $loopAssertionPassed)       { $suffix = ' BUT loop-check FAILED' }
    elseif ($Probe -eq 'blockingload_class_synth' -and -not $flavorAssertionPassed) { $suffix = ' BUT flavor-check FAILED' }
    elseif ($Probe -eq 'wbp_class_synth' -and -not $wbpAssertionPassed)              { $suffix = ' BUT wbp-check FAILED' }
    Write-Host ("VERDICT: $passes of $total events matched$suffix. PROBE FAILED.") -ForegroundColor Red
    exit 1
}
