#requires -Version 7
<#
.SYNOPSIS
    Mid-session add-and-run probe — drops one AS file referencing up to three
    unresolved symbols (asset, class, handle) so the mid-session ticker drains
    them.

.DESCRIPTION
    Asset folder discovered at probe time by parsing `// Discovery root:`
    headers from Script/Generated/*Assets.as and mapping /Game/<X>/ to
    Content/<X>/. Class name is project-neutral. Handle type is fresh-named
    so the dispatcher must synthesize a brand-new JSON entry.

    If no AR config exists, the probe writes a 2-symbol variant (class + handle
    only). If no project handle definitions exist either, writes 1-symbol
    (class only).
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

$asPath = Join-Path $projectRoot 'Script\_probe_mid_session_add.as'
$sidecar = Join-Path $projectRoot 'Script\_probe_mid_session_add.targets.json'

if (Test-Path $asPath) {
    Write-Error "Probe AS file already exists: $asPath — run _probe_mid_session_add_restore.bat first."
    exit 1
}

# ---- Editor-running advisory (Probe B *needs* the editor running) ----
$logDir = Join-Path $projectRoot 'Saved\Logs'
$editorRunning = $false
if (Test-Path $logDir) {
    foreach ($lf in (Get-ChildItem -Path $logDir -Filter "$projectName*.log" -File -ErrorAction SilentlyContinue)) {
        try {
            $fs = [System.IO.File]::Open($lf.FullName, 'Open', 'Write', 'None')
            $fs.Close()
        } catch {
            $editorRunning = $true
            break
        }
    }
}
if (-not $editorRunning) {
    Write-Warning "No $projectName*.log file is locked — editor may not be running. Probe B requires a running editor."
}

# ---- Pick an unaccessed asset (parse Discovery roots from *Assets.as) ----
$pickedAsset = $null
$arFiles = Get-ChildItem -Path $genDir -Filter '*Assets.as' -File -ErrorAction SilentlyContinue
if ($arFiles) {
    # Build existing-accessor set from all *Assets.as files
    $accessorRegex = [regex]'(?m)^\s*TSoftObjectPtr<\w+>\s+(\w+)\s*\(\s*\)'
    $existing = @{}
    foreach ($f in $arFiles) {
        $txt = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($m in $accessorRegex.Matches($txt)) {
            $existing[$m.Groups[1].Value] = $true
        }
    }
    # Parse Discovery roots and map to disk paths
    $discoveryRegex = [regex]'// Discovery root: (/[^\s\r\n]+)'
    $scanDirs = @()
    foreach ($f in $arFiles) {
        $txt = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($m in $discoveryRegex.Matches($txt)) {
            $root = $m.Groups[1].Value
            if ($root -match '^/Game/(.+)') {
                $diskPath = Join-Path $projectRoot "Content\$($matches[1])"
                if (Test-Path $diskPath) { $scanDirs += $diskPath }
            }
            # Plugin mounts (e.g. /CkTests/) skipped — disk path resolution is harder and they
            # often map to plugin Content/ trees outside this project's authoring scope.
        }
    }
    # Prefer simple-typed assets (SM=StaticMesh, T=Texture, M=Material, etc.).
    # BP-suffixed assets often have broken/circular parent class refs that
    # cause Tier 1/2 to fail and Tier 3 to (correctly) refuse — defeating
    # the probe's AR strategy even though the asset exists on disk.
    foreach ($d in $scanDirs) {
        $files = Get-ChildItem -Path $d -Recurse -Filter '*.uasset' -ErrorAction SilentlyContinue | Select-Object -First 5000
        foreach ($u in $files) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($u.Name)
            if ($stem -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
            if ($existing.ContainsKey($stem)) { continue }
            # Skip Blueprint conventions — _BP suffix or _C suffix common for compiled BP classes.
            if ($stem -match '_BP$|_BP_C$') { continue }
            $pickedAsset = $stem
            break
        }
        if ($pickedAsset) { break }
    }
}

# Make class + handle names unique per run. Leftover AS registrations from
# prior runs in the same editor session (or across launches where the JSON
# kept stale entries) would otherwise satisfy the references and silently
# skip DH/ESP stub synthesis.
$probeStamp = (Get-Date -Format 'yyMMddHHmmss')
$className = "UCk_ProbeMidSession${probeStamp}_EntityScript"
$handleType = "FCk_Handle_ProbeMidSession${probeStamp}"

# ---- Build AS body via array join ----
$asLines = @(
    "class $className : UCk_GenericEntityScript_UE"
    '{'
    '    UPROPERTY(ExposeOnSpawn) int32 ProbeValue = 42;'
    ''
    '    UFUNCTION(BlueprintOverride)'
    '    ECk_EntityScript_ConstructionFlow DoConstruct(FCk_Handle& InHandle)'
    '    {'
    '        // Reference our own Params() - triggers EntitySpawnParams stub synthesis'
    "        auto Params = ${className}::Params(ProbeValue);"
)
if ($pickedAsset) {
    $asLines += @(
        '        // Reference an asset that has no accessor yet - triggers AssetRegistry stub synthesis'
        "        auto SoftRef = assets::${pickedAsset}();"
    )
}
$asLines += @(
    '        // Reference a brand-new handle type - triggers DynamicHandle stub synthesis'
    "        $handleType ProbeHandle;"
    '        return ECk_EntityScript_ConstructionFlow::Finished;'
    '    }'
    '}'
    ''
    "asset Probe_NewHandle${probeStamp} of UCkDynamic_HandleDefinition"
    '{'
    "    TypeName = `"$handleType`";"
    "    ShortName = `"ProbeMidSession${probeStamp}`";"
    '    Description = "Integration-probe handle - mid-session add. Restore via _probe_mid_session_add_restore.bat.";'
    '}'
    ''
)
$asBody = ($asLines -join "`r`n")
[System.IO.File]::WriteAllText($asPath, $asBody, [System.Text.UTF8Encoding]::new($false))

$targets = [ordered]@{
    ProjectName    = $projectName
    AssetName      = $pickedAsset
    ClassName      = $className
    HandleTypeName = $handleType
}
$targets | ConvertTo-Json | Set-Content -Path $sidecar -Encoding UTF8

Write-Host "Probe B written: $asPath"
Write-Host "  - PickedAsset: $(if ($pickedAsset) { $pickedAsset } else { '(skipped — no AR configs / no unaccessed assets in /Game/<X>/ roots)' })"
Write-Host "  - ClassName:   $className"
Write-Host "  - HandleType:  $handleType"
Write-Host "  - Sidecar:     $sidecar"
Write-Host ''
Write-Host 'Next steps:'
Write-Host "  1. Watch Saved/Logs/$projectName*.log for mid-session self-heal events"
Write-Host '  2. pwsh _probe_verify.ps1 mid_session_add'
Write-Host '  3. _probe_mid_session_add_restore.bat'
