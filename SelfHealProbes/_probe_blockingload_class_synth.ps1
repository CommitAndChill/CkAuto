#requires -Version 7
<#
.SYNOPSIS
    Probe D — repros the `assets::load::<X>_Class()` synth misclassification.

    Picks a BP-class blocking-load accessor pair from a canonical
    `Script/Generated/*Assets.as` file, snapshots the file, then hand-edits
    the canonical to delete just the `_Class` accessor pair for the target.
    Drops a probe `.as` referencing `assets::load::<Target>_Class()` as the
    sole trigger.

    Editor MUST be running (mid-session ticker is the only entry point that
    will pick up the new probe `.as` and fail the compile). Pairs with
    `_probe_verify.ps1 blockingload_class_synth`.

    Restore via `_probe_blockingload_class_synth_restore.bat` puts the
    canonical back from the sidecar's base64 snapshot.
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

$asPath  = Join-Path $projectRoot 'Script\_probe_blockingload_class_synth.as'
$sidecar = Join-Path $projectRoot 'Script\_probe_blockingload_class_synth.targets.json'

if (Test-Path $asPath) {
    Write-Error "Probe AS file already exists: $asPath - run _probe_blockingload_class_synth_restore.bat first."
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

# ---- Pick a BP-class blocking-load accessor target ----
# Need:
#   1. A `TSubclassOf<X> <NAME>_Class()` block in a canonical *Assets.as inside
#      a `namespace assets::load {...}` (or plugin-scoped equivalent) block.
#   2. The matching `<NAME>.uasset` exists on disk under the file's
#      `// Discovery root:` header.
# Skip patterns:
#   - WBP-class accessors (Tier 2 LoadObject failure - a different bug;
#     would muddy the probe's signal).
$pickedAccessor   = $null
$pickedNamespace  = $null
$pickedAssetClass = $null
$pickedFile       = $null

$arFiles = Get-ChildItem -Path $genDir -Filter '*Assets.as' -File -ErrorAction SilentlyContinue
if (-not $arFiles) {
    Write-Error "No Script/Generated/*Assets.as files found - nothing to probe against."
    exit 1
}

$blockingClassRegex = [regex]'(?m)^\s*TSubclassOf<(\w+)>\s+(\w+)_Class\s*\(\s*\)\s*$'
$discoveryRegex     = [regex]'(?m)^//\s*Discovery root:\s*(/[^\s\r\n]+)'

foreach ($f in $arFiles) {
    $txt = [System.IO.File]::ReadAllText($f.FullName)

    # Pull discovery root(s) for this file
    $rootMatches = $discoveryRegex.Matches($txt)
    if ($rootMatches.Count -eq 0) { continue }

    # Map /Game/<X>/ -> <project>/Content/<X>/. Plugin mounts (/CkTests/ etc.)
    # are harder to resolve to disk; skip for picker simplicity.
    $diskRoots = @()
    foreach ($m in $rootMatches) {
        $root = $m.Groups[1].Value
        if ($root -match '^/Game/(.+)') {
            $candidate = Join-Path $projectRoot ("Content\" + ($matches[1] -replace '/', '\'))
            if (Test-Path $candidate) { $diskRoots += $candidate }
        }
    }
    if ($diskRoots.Count -eq 0) { continue }

    foreach ($m in $blockingClassRegex.Matches($txt)) {
        $assetClass = $m.Groups[1].Value
        $name       = $m.Groups[2].Value

        # Skip WBP class accessors - they hit a different Tier-2 bug.
        if ($name -match '_WBP$') { continue }

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

        # Sniff the namespace this accessor lives in. Conservative: walk
        # backward from the match to find the most recent `namespace <X> {`.
        $beforeText = $txt.Substring(0, $m.Index)
        $nsMatch = [regex]::Matches($beforeText, '(?m)^namespace\s+(\S+)\s*\{')
        if ($nsMatch.Count -gt 0) {
            $pickedNamespace = $nsMatch[$nsMatch.Count - 1].Groups[1].Value
        } else {
            $pickedNamespace = 'assets::load'  # fallback for typical case
        }
        break
    }
    if ($pickedAccessor) { break }
}

if (-not $pickedAccessor) {
    Write-Error "No BP-class blocking accessor with a locatable on-disk asset under /Game/* was found. This project may have only plugin-mounted BP-class accessors, or none at all."
    exit 1
}

# Sanity: the namespace we pull off must look like `*::load` (this probe is
# specifically for the BlockingLoadClass flavor). If it's e.g. plain `assets`,
# we picked from the wrong block - bail rather than misfire.
if (-not $pickedNamespace.EndsWith('::load')) {
    Write-Error "Picked accessor '$pickedAccessor' is in namespace '$pickedNamespace' (expected `*::load`). Probe picker logic mis-identified the namespace; bailing."
    exit 1
}

$softNamespace = $pickedNamespace -replace '::load$', ''

Write-Host "Picked target: $pickedNamespace::${pickedAccessor}_Class() -> TSubclassOf<$pickedAssetClass>" -ForegroundColor DarkCyan
Write-Host "  Canonical: $pickedFile" -ForegroundColor DarkGray

# ---- Snapshot the canonical file ----
$originalBytes  = [System.IO.File]::ReadAllBytes($pickedFile)
$originalBase64 = [Convert]::ToBase64String($originalBytes)

# ---- Edit the canonical to remove BOTH the soft and blocking _Class accessors ----
# Two patterns to strip from the file text (using the original encoding round-trip).
# Encoding: most canonical files are UTF-8 no-BOM (ASCII); read+write with the
# same byte representation.
$origText = [System.Text.Encoding]::UTF8.GetString($originalBytes)

# Soft-class accessor (single line) inside `namespace <soft>` block:
#   `    TSoftClassPtr<X> Name_Class() { return TSoftClassPtr<X>(FSoftObjectPath("...")); }`
$softLineRe = [regex]("(?m)^\s*TSoftClassPtr<\w+>\s+" + [regex]::Escape($pickedAccessor) + "_Class\s*\(\s*\)\s*\{[^\n]*\}\s*\r?\n")

# Blocking-class accessor (multi-line) inside `namespace <soft>::load` block:
#   `    TSubclassOf<X> Name_Class()`
#   `    {`
#   `        if (ck::EnsureIfNot(...))`
#   `        { return nullptr; }`
#   `        return System::LoadClassAsset_Blocking(<soft>::Name_Class());`
#   `    }`
# Inner LoadClassAsset_Blocking arg contains `)` (the soft accessor call), so
# anchor the inner match on `;` rather than `)` to avoid stopping early.
$blockingBlockRe = [regex]("(?ms)^\s*TSubclassOf<\w+>\s+" + [regex]::Escape($pickedAccessor) + "_Class\s*\(\s*\)\s*\r?\n\s*\{.+?LoadClassAsset_Blocking\(.+?\)\s*;\s*\r?\n\s*\}\s*\r?\n")

$newText = $softLineRe.Replace($origText, '', 1)
if ($newText -eq $origText) {
    Write-Error "Soft-class line for '$pickedAccessor`_Class' not found by regex in canonical - probe author needs updating."
    exit 1
}
$newText2 = $blockingBlockRe.Replace($newText, '', 1)
if ($newText2 -eq $newText) {
    Write-Error "Blocking-class block for '$pickedAccessor`_Class' not found by regex in canonical - probe author needs updating."
    exit 1
}

# Write back with UTF-8 no-BOM (matches original observed encoding).
[System.IO.File]::WriteAllText($pickedFile, $newText2, [System.Text.UTF8Encoding]::new($false))

# ---- Drop the probe .as file ----
$probeStamp = (Get-Date -Format 'yyMMddHHmmss')
$className  = "UCk_ProbeBlockingLoadClass${probeStamp}_EntityScript"

$asLines = @(
    "// Probe D - BlockingLoadClass synth-flavor reproduction."
    "// Target accessor: $pickedNamespace::${pickedAccessor}_Class() -> TSubclassOf<$pickedAssetClass>"
    "// Stamp: $probeStamp"
    "// Restore: CkAuto\SelfHealProbes\_probe_blockingload_class_synth_restore.bat"
    ''
    "class $className : UCk_GenericEntityScript_UE"
    '{'
    '    UFUNCTION(BlueprintOverride)'
    '    ECk_EntityScript_ConstructionFlow DoConstruct(FCk_Handle& InHandle)'
    '    {'
    "        auto Cls = ${pickedNamespace}::${pickedAccessor}_Class();"
    '        return ECk_EntityScript_ConstructionFlow::Finished;'
    '    }'
    '}'
    ''
)
[System.IO.File]::WriteAllText($asPath, ($asLines -join "`r`n"), [System.Text.UTF8Encoding]::new($false))

# ---- Sidecar ----
$targets = [ordered]@{
    ProjectName    = $projectName
    AccessorName   = $pickedAccessor          # e.g. "Explosion_BB_CS" (no _Class)
    AssetClassName = $pickedAssetClass        # e.g. "UCameraShakeBase"
    Namespace      = $pickedNamespace         # e.g. "assets::load"
    SoftNamespace  = $softNamespace           # e.g. "assets"
    CanonicalFile  = $pickedFile
    OriginalBase64 = $originalBase64
    ClassName      = $className
    ProbeStamp     = $probeStamp
}
$targets | ConvertTo-Json -Depth 4 | Set-Content -Path $sidecar -Encoding UTF8

Write-Host ""
Write-Host "Probe D written:" -ForegroundColor Green
Write-Host "  - Canonical edited (soft+blocking _Class pair removed): $pickedFile"
Write-Host "  - Probe AS file:  $asPath"
Write-Host "  - Sidecar:        $sidecar"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Watch Saved/Logs/$projectName*.log - wait ~30s after AS hot-reload kicks."
Write-Host "  2. pwsh _probe_verify.ps1 blockingload_class_synth -Tail"
Write-Host "  3. _probe_blockingload_class_synth_restore.bat"
