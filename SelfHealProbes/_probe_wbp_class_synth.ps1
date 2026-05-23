#requires -Version 7
<#
.SYNOPSIS
    Probe E — repros the `assets::<X>_WBP_Class()` Tier 2 LoadObject failure
    for WidgetBlueprints whose ParentClass is an AS-defined UClass.

    Picks a WBP soft-class accessor from a canonical
    `Script/Generated/*Assets.as` file, snapshots the file, hand-edits the
    canonical to delete the soft-class accessor pair (and matching blocking
    sibling if present) for the target, and drops a probe `.as` referencing
    `assets::<Target>_WBP_Class()` as the sole trigger.

    Editor MUST be running (mid-session ticker is the only entry point that
    will pick up the new probe `.as` and fail the compile). Pairs with
    `_probe_verify.ps1 wbp_class_synth`.

    Pre-fix RED signature: the dispatcher fails three times with
        `Could not resolve UClass ... LoadObject ... Tier 3 ... disabled`
    and the convergence-cap blacklists the signature for the rest of the
    session.

    Post-fix GREEN signature: the dispatcher logs `Synthesized AssetRegistry
    stub for assets::<Target>_WBP_Class()` — the Tier 2.5 AssetData
    NativeParentClass tag fallback resolved the native parent.

    Restore via `_probe_wbp_class_synth_restore.bat` puts the canonical back
    from the sidecar's base64 snapshot.
#>

$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$uproject = Get-ChildItem -Path $projectRoot -Filter '*.uproject' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $uproject) {
    Write-Error "No .uproject found at $projectRoot."
    exit 1
}
$projectName = [System.IO.Path]::GetFileNameWithoutExtension($uproject.Name)
$genDir = Join-Path $projectRoot 'Script\Generated'

Write-Host "Project: $projectName ($projectRoot)" -ForegroundColor Cyan

$asPath  = Join-Path $projectRoot 'Script\_probe_wbp_class_synth.as'
$sidecar = Join-Path $projectRoot 'Script\_probe_wbp_class_synth.targets.json'

if (Test-Path $asPath) {
    Write-Error "Probe AS file already exists: $asPath - run _probe_wbp_class_synth_restore.bat first."
    exit 1
}

# ---- Editor-running advisory (this probe needs mid-session ticker) ----
$logDir = Join-Path $projectRoot 'Saved\Logs'
$editorRunning = $false
if (Test-Path $logDir) {
    foreach ($lf in (Get-ChildItem -Path $logDir -Filter "$projectName*.log" -File -ErrorAction SilentlyContinue)) {
        try { $fs = [System.IO.File]::Open($lf.FullName, 'Open', 'Write', 'None'); $fs.Close() }
        catch { $editorRunning = $true; break }
    }
}
if (-not $editorRunning) {
    Write-Warning "No $projectName*.log file is locked - editor may not be running. This probe needs the editor up so the mid-session ticker fires when the new .as file lands."
}

# ---- Blacklist advisory ----
# If a signature already convergence-failed earlier in this editor session, the
# per-signature cap suppresses any further dispatcher attempts for that key
# until restart. Warn if any of our candidate signatures appear in the newest
# log's convergence-failed lines so the user knows to restart before this run.
$blacklistedSignatures = @()
$newestLog = Get-ChildItem -Path $logDir -Filter "$projectName*.log" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newestLog) {
    $convFailRegex = [regex]'Convergence failed for assets::(\w+_WBP)_Class\(\)'
    foreach ($line in (Get-Content -LiteralPath $newestLog.FullName -Encoding UTF8)) {
        $m = $convFailRegex.Match($line)
        if ($m.Success) { $blacklistedSignatures += $m.Groups[1].Value }
    }
    $blacklistedSignatures = $blacklistedSignatures | Sort-Object -Unique
    if ($blacklistedSignatures.Count -gt 0) {
        Write-Host ""
        Write-Host "Blacklisted WBP signatures in current session (from $($newestLog.Name)):" -ForegroundColor Yellow
        foreach ($s in $blacklistedSignatures) { Write-Host "  - $s" -ForegroundColor Yellow }
        Write-Host "These will be excluded from picker candidates. If none remain, restart the editor first." -ForegroundColor Yellow
    }
}

# ---- Pick a WBP soft-class accessor target ----
# Need:
#   1. A `TSoftClassPtr<X> <NAME>_Class()` block in a canonical *Assets.as
#      inside `namespace assets {...}` (NOT `assets::load` — that's Probe D).
#   2. NAME ends with `_WBP` (so we're targeting a WidgetBlueprint, the
#      class of asset whose AS-parented variant breaks LoadObject Tier 2).
#   3. The matching `<NAME>.uasset` exists on disk under the file's
#      `// Discovery root:` header.
#   4. NAME is NOT in $blacklistedSignatures (convergence-blacklisted this
#      session; dispatcher won't retry).
$pickedAccessor   = $null
$pickedNamespace  = $null
$pickedAssetClass = $null
$pickedFile       = $null

$arFiles = Get-ChildItem -Path $genDir -Filter '*Assets.as' -File -ErrorAction SilentlyContinue
if (-not $arFiles) {
    Write-Error "No Script/Generated/*Assets.as files found - nothing to probe against."
    exit 1
}

$softClassRegex = [regex]'(?m)^\s*TSoftClassPtr<(\w+)>\s+(\w+)_Class\s*\(\s*\)\s*\{'
$discoveryRegex = [regex]'(?m)^//\s*Discovery root:\s*(/[^\s\r\n]+)'

foreach ($f in $arFiles) {
    $txt = [System.IO.File]::ReadAllText($f.FullName)

    $rootMatches = $discoveryRegex.Matches($txt)
    if ($rootMatches.Count -eq 0) { continue }

    $diskRoots = @()
    foreach ($m in $rootMatches) {
        $root = $m.Groups[1].Value
        if ($root -match '^/Game/(.+)') {
            $candidate = Join-Path $projectRoot ("Content\" + ($matches[1] -replace '/', '\'))
            if (Test-Path $candidate) { $diskRoots += $candidate }
        }
    }
    if ($diskRoots.Count -eq 0) { continue }

    foreach ($m in $softClassRegex.Matches($txt)) {
        $assetClass = $m.Groups[1].Value
        $name       = $m.Groups[2].Value

        # WBP-only: this probe specifically exercises the Tier 2.5 path.
        if ($name -notmatch '_WBP$') { continue }

        # Skip blacklisted signatures from current session.
        if ($blacklistedSignatures -contains $name) { continue }

        # Must be inside `namespace assets {...}` (NOT ::load).
        $beforeText = $txt.Substring(0, $m.Index)
        $nsMatch = [regex]::Matches($beforeText, '(?m)^namespace\s+(\S+)\s*\{')
        if ($nsMatch.Count -eq 0) { continue }
        $thisNs = $nsMatch[$nsMatch.Count - 1].Groups[1].Value
        if ($thisNs -ne 'assets') { continue }

        # Locate `<name>.uasset` under any disk root.
        $found = $null
        foreach ($d in $diskRoots) {
            $hit = Get-ChildItem -Path $d -Recurse -Filter "$name.uasset" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $found = $hit; break }
        }
        if (-not $found) { continue }

        $pickedAccessor   = $name
        $pickedAssetClass = $assetClass
        $pickedFile       = $f.FullName
        $pickedNamespace  = $thisNs
        break
    }
    if ($pickedAccessor) { break }
}

if (-not $pickedAccessor) {
    Write-Error "No WBP soft-class accessor with a locatable on-disk asset under /Game/* was found (or all candidates were convergence-blacklisted). If candidates were blacklisted: restart the editor and rerun. If none exist: BB content has no WBP _Class accessors the probe can target."
    exit 1
}

Write-Host "Picked target: assets::${pickedAccessor}_Class() -> TSoftClassPtr<$pickedAssetClass>" -ForegroundColor DarkCyan
Write-Host "  Canonical: $pickedFile" -ForegroundColor DarkGray

# ---- Snapshot the canonical file ----
$originalBytes  = [System.IO.File]::ReadAllBytes($pickedFile)
$originalBase64 = [Convert]::ToBase64String($originalBytes)

$origText = [System.Text.Encoding]::UTF8.GetString($originalBytes)

# Soft-class accessor (single line) inside `namespace assets` block:
#   `    TSoftClassPtr<X> Name_Class() { return TSoftClassPtr<X>(FSoftObjectPath("...")); }`
$softLineRe = [regex]("(?m)^\s*TSoftClassPtr<\w+>\s+" + [regex]::Escape($pickedAccessor) + "_Class\s*\(\s*\)\s*\{[^\n]*\}\s*\r?\n")

# Blocking-class accessor (multi-line) inside `namespace assets::load` block - may or may not exist.
$blockingBlockRe = [regex]("(?ms)^\s*TSubclassOf<\w+>\s+" + [regex]::Escape($pickedAccessor) + "_Class\s*\(\s*\)\s*\r?\n\s*\{.+?LoadClassAsset_Blocking\([^)]+\)\s*;\s*\r?\n\s*\}\s*\r?\n")

$newText = $softLineRe.Replace($origText, '', 1)
if ($newText -eq $origText) {
    Write-Error "Soft-class line for '${pickedAccessor}_Class' not found by regex in canonical - probe author needs updating."
    exit 1
}

# Blocking sibling is best-effort; not all WBPs emit one.
$newText2 = $blockingBlockRe.Replace($newText, '', 1)

[System.IO.File]::WriteAllText($pickedFile, $newText2, [System.Text.UTF8Encoding]::new($false))

# ---- Drop the probe .as file ----
$probeStamp = (Get-Date -Format 'yyMMddHHmmss')
$className  = "UCk_ProbeWbpClassSynth${probeStamp}_EntityScript"

$asLines = @(
    "// Probe E - WBP _Class Tier 2.5 (AssetData NativeParentClass tag) reproduction."
    "// Target accessor: assets::${pickedAccessor}_Class() -> TSoftClassPtr<$pickedAssetClass>"
    "// Stamp: $probeStamp"
    "// Restore: CkAuto\SelfHealProbes\_probe_wbp_class_synth_restore.bat"
    ''
    "class $className : UCk_GenericEntityScript_UE"
    '{'
    '    UFUNCTION(BlueprintOverride)'
    '    ECk_EntityScript_ConstructionFlow DoConstruct(FCk_Handle& InHandle)'
    '    {'
    "        auto Cls = assets::${pickedAccessor}_Class();"
    '        return ECk_EntityScript_ConstructionFlow::Finished;'
    '    }'
    '}'
    ''
)
[System.IO.File]::WriteAllText($asPath, ($asLines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))

# ---- Sidecar ----
$targets = [ordered]@{
    ProjectName    = $projectName
    AccessorName   = $pickedAccessor          # e.g. "SomeFoo_BB_WBP" (no _Class)
    AssetClassName = $pickedAssetClass        # e.g. "UUserWidget"
    Namespace      = $pickedNamespace         # always "assets" for this probe
    CanonicalFile  = $pickedFile
    OriginalBase64 = $originalBase64
    ClassName      = $className
    ProbeStamp     = $probeStamp
}
$targets | ConvertTo-Json -Depth 4 | Set-Content -Path $sidecar -Encoding UTF8

Write-Host ""
Write-Host "Probe E written:" -ForegroundColor Green
Write-Host "  - Canonical edited (soft+blocking _Class pair removed): $pickedFile"
Write-Host "  - Probe AS file:  $asPath"
Write-Host "  - Sidecar:        $sidecar"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Watch Saved/Logs/$projectName*.log - wait ~30s after AS hot-reload kicks."
Write-Host "  2. pwsh _probe_verify.ps1 wbp_class_synth -Tail"
Write-Host "  3. _probe_wbp_class_synth_restore.bat"
