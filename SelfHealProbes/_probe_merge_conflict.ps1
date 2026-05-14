#requires -Version 7
<#
.SYNOPSIS
    Cold-start merge-conflict probe — drifts up to three generated files to
    exercise the AS self-heal dispatcher's multi-strategy bootstrap drain.

.DESCRIPTION
    Picks drift targets at probe time, requiring each target to have at least
    one referencing call-site under Script/ (excluding Script/Generated/):
      • AssetRegistry strategy: first TSoftObjectPtr<X> accessor in any
        Script/Generated/*Assets.as that is also called as `assets::<Name>(`
        from non-generated AS code.
      • DynamicHandle strategy: first HandleTypes[] entry whose TypeName
        appears as a type or As_<X>() method call in non-generated AS code.
      • EntitySpawnParams strategy: first ^namespace block whose name appears
        as `<Namespace>::Params(` in non-generated AS code.

    Each strategy independently skips if no callable target found. Sidecar
    (_probe_merge_conflict.targets.json) records what got drifted.
#>

$ErrorActionPreference = 'Stop'

# ---- Resolve project root + project name from script location ----
$projectRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$uproject = Get-ChildItem -Path $projectRoot -Filter '*.uproject' -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $uproject) {
    Write-Error "No .uproject found at $projectRoot — script must live two levels under a project root."
    exit 1
}
$projectName = [System.IO.Path]::GetFileNameWithoutExtension($uproject.Name)
$genDir = Join-Path $projectRoot 'Script\Generated'
$scriptDir = Join-Path $projectRoot 'Script'

Write-Host "Project: $projectName ($projectRoot)" -ForegroundColor Cyan

# ---- Refuse if editor is running (probe any <Project>*.log for a write lock) ----
$logDir = Join-Path $projectRoot 'Saved\Logs'
if (Test-Path $logDir) {
    $logFiles = Get-ChildItem -Path $logDir -Filter "$projectName*.log" -File -ErrorAction SilentlyContinue
    foreach ($lf in $logFiles) {
        try {
            $fs = [System.IO.File]::Open($lf.FullName, 'Open', 'Write', 'None')
            $fs.Close()
        }
        catch {
            Write-Error "Editor appears to be running ($($lf.Name) is locked). Close ${projectName}Editor.exe and retry."
            exit 1
        }
    }
}

# ---- Refuse if any backup already exists ----
$sidecar = Join-Path $genDir '_probe_merge_conflict.targets.json'
if (Test-Path $sidecar) {
    Write-Error "Sidecar already exists: $sidecar — run _probe_merge_conflict_restore.bat first."
    exit 1
}
$anyBak = Get-ChildItem -Path $genDir -Include '*.assetsbak', '*.handlebak', '*.entitybak' -File -Recurse -ErrorAction SilentlyContinue
if ($anyBak) {
    Write-Error "Backup files already exist under $genDir — run _probe_merge_conflict_restore.bat first."
    exit 1
}

# ---- Index all non-generated AS source bodies into a single concatenated blob ----
$asSources = Get-ChildItem -Path $scriptDir -Filter '*.as' -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\Generated\\' }
$asBlob = [System.Text.StringBuilder]::new()
foreach ($f in $asSources) {
    $null = $asBlob.AppendLine([System.IO.File]::ReadAllText($f.FullName))
}
$asBlobStr = $asBlob.ToString()

function Test-AsCallerExists {
    Param([string]$Pattern)
    return [regex]::IsMatch($asBlobStr, $Pattern)
}

$targets = [ordered]@{
    ProjectName = $projectName
    Drifts = [ordered]@{}
}

# ---- AssetRegistry strategy: pick first accessor with an AS caller ----
$assetsFile = $null
$pickedAccessor = $null
$arFiles = Get-ChildItem -Path $genDir -Filter '*Assets.as' -File -ErrorAction SilentlyContinue
$accessorRegex = [regex]'(?m)^\s*TSoftObjectPtr<\w+>\s+(\w+)\s*\(\s*\)'
:arLoop foreach ($f in $arFiles) {
    $content = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($m in $accessorRegex.Matches($content)) {
        $name = $m.Groups[1].Value
        # Caller pattern: assets::<Name>(  or  assets::load::<Name>(
        $callerPattern = "assets::(load::)?$([regex]::Escape($name))\("
        if (Test-AsCallerExists $callerPattern) {
            $pickedAccessor = $name
            $assetsFile = $f.FullName
            break arLoop
        }
    }
}
if ($pickedAccessor) {
    $bak = $assetsFile + '.assetsbak'
    Copy-Item $assetsFile $bak
    $orig = [System.IO.File]::ReadAllText($assetsFile)
    $pattern = "(?m)^\s*TSoftObjectPtr<\w+>\s+$([regex]::Escape($pickedAccessor))\(\)[^\r\n]*\r?\n"
    $new = [System.Text.RegularExpressions.Regex]::Replace($orig, $pattern, '')
    [System.IO.File]::WriteAllText($assetsFile, $new, [System.Text.UTF8Encoding]::new($false))
    $targets.Drifts['AssetRegistry'] = [ordered]@{
        File = $assetsFile
        Backup = $bak
        Accessor = $pickedAccessor
    }
    Write-Host "  [DRIFT] AssetRegistry: removed assets::$pickedAccessor() from $(Split-Path -Leaf $assetsFile)" -ForegroundColor Yellow
}
else {
    Write-Host '  [SKIP] AssetRegistry: no *Assets.as accessor with an AS caller found' -ForegroundColor DarkGray
}

# ---- DynamicHandle strategy: pick first HandleTypes[] entry with an AS caller ----
$dhFile = Join-Path $genDir 'DynamicHandleTypes.json'
$pickedHandle = $null
if (Test-Path $dhFile) {
    $dh = Get-Content $dhFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($dh.HandleTypes) {
        foreach ($entry in $dh.HandleTypes) {
            # ShortName is what AS callers use (e.g. As_CheckoutCounter() or FCk_Handle_CheckoutCounter as type)
            $short = $entry.ShortName
            $tn = $entry.TypeName
            # Caller patterns: FCk_Handle_<X>  OR  As_<ShortName>(
            $pat1 = "\b$([regex]::Escape($tn))\b"
            $pat2 = if ($short) { "\bAs_$([regex]::Escape($short))\(" } else { $null }
            if ((Test-AsCallerExists $pat1) -or ($pat2 -and (Test-AsCallerExists $pat2))) {
                $pickedHandle = $tn
                break
            }
        }
    }
    if ($pickedHandle) {
        $bak = $dhFile + '.handlebak'
        Copy-Item $dhFile $bak
        $dh.HandleTypes = @($dh.HandleTypes | Where-Object { $_.TypeName -ne $pickedHandle })
        $dh | ConvertTo-Json -Depth 10 | Set-Content -Path $dhFile -Encoding UTF8
        $targets.Drifts['DynamicHandle'] = [ordered]@{
            File = $dhFile
            Backup = $bak
            TypeName = $pickedHandle
        }
        Write-Host "  [DRIFT] DynamicHandle: removed $pickedHandle from DynamicHandleTypes.json" -ForegroundColor Yellow
    }
    else {
        Write-Host '  [SKIP] DynamicHandle: no entries with an AS caller found' -ForegroundColor DarkGray
    }
}
else {
    Write-Host '  [SKIP] DynamicHandle: no DynamicHandleTypes.json in Script/Generated/' -ForegroundColor DarkGray
}

# ---- EntitySpawnParams strategy: pick first namespace with an AS ::Params caller ----
$espFile = $null
$pickedNamespace = $null
$espCandidates = Get-ChildItem -Path $genDir -Filter '*_EntitySpawnParams.as' -File -ErrorAction SilentlyContinue
$nsRegex = [regex]'(?m)^namespace (U\w+)\s*\{'
:espLoop foreach ($f in $espCandidates) {
    $content = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($m in $nsRegex.Matches($content)) {
        $ns = $m.Groups[1].Value
        $callerPattern = "$([regex]::Escape($ns))::Params\("
        if (Test-AsCallerExists $callerPattern) {
            $pickedNamespace = $ns
            $espFile = $f.FullName
            break espLoop
        }
    }
}
if ($pickedNamespace) {
    $bak = $espFile + '.entitybak'
    Copy-Item $espFile $bak
    $orig = [System.IO.File]::ReadAllText($espFile)
    $pattern = "(?ms)^namespace $([regex]::Escape($pickedNamespace))\s*\{.*?^\}\s*\r?\n"
    $new = [System.Text.RegularExpressions.Regex]::Replace($orig, $pattern, '')
    [System.IO.File]::WriteAllText($espFile, $new, [System.Text.UTF8Encoding]::new($false))
    $targets.Drifts['EntitySpawnParams'] = [ordered]@{
        File = $espFile
        Backup = $bak
        Namespace = $pickedNamespace
    }
    Write-Host "  [DRIFT] EntitySpawnParams: removed namespace $pickedNamespace from $(Split-Path -Leaf $espFile)" -ForegroundColor Yellow
}
else {
    Write-Host '  [SKIP] EntitySpawnParams: no namespace with an AS ::Params caller found' -ForegroundColor DarkGray
}

# ---- Write sidecar (always, even with zero drifts so verifier can read state) ----
# Ensure Script/Generated/ exists for the sidecar; create if not (no-op project case).
if (-not (Test-Path $genDir)) { New-Item -ItemType Directory -Path $genDir | Out-Null }
$targets | ConvertTo-Json -Depth 6 | Set-Content -Path $sidecar -Encoding UTF8

Write-Host ''
if ($targets.Drifts.Count -eq 0) {
    Write-Host "No drifts applicable for this project — Script/Generated/ has nothing with active AS callers." -ForegroundColor Yellow
    Write-Host "Sidecar written (empty Drifts): $sidecar"
    Write-Host 'This is the expected outcome for projects without AR configs / dynamic handles / entity scripts yet.'
    exit 0
}

Write-Host "Probe A drift complete ($($targets.Drifts.Count) strategy/strategies)."
Write-Host "Sidecar: $sidecar"
Write-Host ''
Write-Host 'Next steps:'
Write-Host "  1. Launch ${projectName}Editor.exe; bootstrap self-heal should fire"
Write-Host '  2. Wait for main screen (settled)'
Write-Host '  3. pwsh _probe_verify.ps1 merge_conflict'
Write-Host '  4. _probe_merge_conflict_restore.bat'
