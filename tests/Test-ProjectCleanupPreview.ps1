param(
    [string] $FixtureRoot = (Join-Path ([System.IO.Path]::GetTempPath()) 'CkAuto-StorageTests')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\Common\ProjectCleanupPreview.psm1') -Force -ErrorAction Stop
[void] [System.IO.Directory]::CreateDirectory($FixtureRoot)

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Assert-Throws([scriptblock] $operation, [string] $message) {
    $threw = $false
    try { & $operation | Out-Null }
    catch { $threw = $true }
    Assert-True $threw $message
}

function New-FixtureFile([string] $path, [int] $size) {
    $parent = Split-Path -Parent $path
    [void] (New-Item -ItemType Directory -Path $parent -Force)
    [System.IO.File]::WriteAllBytes($path, (New-Object byte[] $size))
}

$case = Join-Path $FixtureRoot ('cleanup-preview-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $case 'Example'
$outside = Join-Path $case 'Outside'
[void] (New-Item -ItemType Directory -Path $project -Force)
[void] (New-Item -ItemType Directory -Path $outside -Force)
$projectFile = Join-Path $project 'Example.uproject'
[System.IO.File]::WriteAllText($projectFile, '{}')

$intermediate = Join-Path $project 'Intermediate\Build\Win64\UnrealEditor\DebugGame\Generated.obj'
$precompiledHeader = Join-Path $project 'Intermediate\Build\Win64\UnrealEditor\DebugGame\Shared.pch'
$resource = Join-Path $project 'Intermediate\Build\Win64\UnrealEditor\DebugGame\Generated.res'
$binary = Join-Path $project 'Binaries\Win64\Example-Win64-DebugGame.pdb'
$plugin = Join-Path $project 'Plugins\ExamplePlugin'
$pluginFile = Join-Path $plugin 'Intermediate\Build\Win64\DebugGame\Plugin.json'
$source = Join-Path $project 'Source\Example.cpp'
$asset = Join-Path $project 'Content\Map.uasset'
$development = Join-Path $project 'Binaries\Win64\Example-Win64-Development.dll'
$undecorated = Join-Path $project 'Binaries\Win64\Example.dll'
$wrongConfig = Join-Path $project 'Intermediate\Build\Win64\Development\Other.obj'
$excludedSource = Join-Path $project 'Intermediate\Build\Win64\DebugGame\Source\Keep.obj'
$excludedEngine = Join-Path $project 'Binaries\Engine\Engine-Win64-DebugGame.dll'
$wrongExtension = Join-Path $project 'Intermediate\Build\Win64\DebugGame\Notes.txt'
$generatedSource = Join-Path $project 'Intermediate\Build\Win64\DebugGame\Generated.cpp'
$generatedHeader = Join-Path $project 'Intermediate\Build\Win64\DebugGame\Generated.h'
$wrongDecoration = Join-Path $project 'Binaries\Win64\Example-Win64-DebugGame-extra.dll'
$outsideFile = Join-Path $outside 'External-Win64-DebugGame.dll'

New-FixtureFile $intermediate 3
New-FixtureFile $precompiledHeader 47
New-FixtureFile $resource 53
New-FixtureFile $binary 5
New-FixtureFile $pluginFile 7
New-FixtureFile $source 11
New-FixtureFile $asset 13
New-FixtureFile $development 17
New-FixtureFile $undecorated 19
New-FixtureFile $wrongConfig 23
New-FixtureFile $excludedSource 31
New-FixtureFile $excludedEngine 37
New-FixtureFile $wrongExtension 41
New-FixtureFile $generatedSource 59
New-FixtureFile $generatedHeader 61
New-FixtureFile $wrongDecoration 43
New-FixtureFile $outsideFile 29
[System.IO.File]::WriteAllText((Join-Path $plugin 'ExamplePlugin.uplugin'), '{}')

$junction = Join-Path $project 'Binaries\Win64\External'
[void] (New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop)

$allFiles = @($projectFile, $intermediate, $precompiledHeader, $resource, $binary, $pluginFile, $source, $asset,
    $development, $undecorated, $wrongConfig, $excludedSource, $excludedEngine,
    $wrongExtension, $generatedSource, $generatedHeader, $wrongDecoration, $outsideFile,
    (Join-Path $plugin 'ExamplePlugin.uplugin'))
$before = @{}
foreach ($file in $allFiles) {
    $before[$file] = [pscustomobject]@{
        Bytes = [System.IO.File]::ReadAllBytes($file)
        Time = [System.IO.File]::GetLastWriteTimeUtc($file)
    }
}

$preview = Get-ProjectCleanupPreview -Project $project -Configuration DebugGame
$actual = @($preview.Candidates | ForEach-Object { $_.Path } | Sort-Object)
$expected = @($intermediate, $precompiledHeader, $resource, $binary, $pluginFile | Sort-Object)
Assert-True ($preview.CandidateCount -eq 5) 'Expected exactly five generated files.'
Assert-True ($preview.LogicalBytes -eq 115) 'Logical byte total is incorrect.'
Assert-True ($preview.SkippedReparsePoints -ge 1) 'The junction was not reported as skipped.'
Assert-True ($preview.ProjectFile -eq $projectFile) 'Project resolution returned the wrong project file.'
Assert-True ((Compare-Object -ReferenceObject $expected -DifferenceObject $actual).Count -eq 0) 'Candidate paths do not match the bounded fixture.'
Assert-True (@($preview.Candidates | Where-Object { [string]::IsNullOrWhiteSpace($_.Reason) }).Count -eq 0) 'Candidate reason is missing.'
$byFile = Get-ProjectCleanupPreview -Project $projectFile
Assert-True ($byFile.CandidateCount -eq $preview.CandidateCount -and $byFile.LogicalBytes -eq $preview.LogicalBytes) 'The .uproject path should resolve to the same preview.'

foreach ($file in $allFiles) {
    $afterBytes = [System.IO.File]::ReadAllBytes($file)
    Assert-True ([System.Linq.Enumerable]::SequenceEqual([byte[]] $before[$file].Bytes, [byte[]] $afterBytes)) "Preview changed bytes: $file"
    Assert-True ([System.IO.File]::GetLastWriteTimeUtc($file) -eq $before[$file].Time) "Preview changed timestamp: $file"
}

$missing = Join-Path $case 'Missing'
[void] (New-Item -ItemType Directory -Path $missing)
Assert-Throws { Get-ProjectCleanupPreview -Project $missing } 'Missing project should fail.'
Assert-Throws { Get-ProjectCleanupPreview -Project (Join-Path $missing 'Unknown.uproject') } 'Invalid project path should fail.'
$ambiguous = Join-Path $case 'Ambiguous'
[void] (New-Item -ItemType Directory -Path $ambiguous)
[System.IO.File]::WriteAllText((Join-Path $ambiguous 'First.uproject'), '{}')
[System.IO.File]::WriteAllText((Join-Path $ambiguous 'Second.uproject'), '{}')
Assert-Throws { Get-ProjectCleanupPreview -Project $ambiguous } 'Ambiguous project should fail.'
Assert-Throws { Get-ProjectCleanupPreview -Project $project -Configuration Development } 'Unsupported configuration should fail.'
Assert-Throws { Get-ProjectCleanupPreview -Project $project -Configuration @() } 'Empty configuration should fail.'

Write-Output "PASS ProjectCleanupPreview: $case"
