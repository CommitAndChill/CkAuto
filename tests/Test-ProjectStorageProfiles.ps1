<#
Focused, filesystem-only checks for the project storage profile module.
Run with Windows PowerShell 5.1 or PowerShell 7. Fixtures remain in the task work
directory for inspection; this test never deletes a tree or touches a real project.
#>
param(
    [string] $FixtureParent = (Join-Path ([IO.Path]::GetTempPath()) 'CkAuto-StorageTests')
)

$ErrorActionPreference = 'Stop'
$ModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Common\ProjectStorage.psm1'
if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) { throw "Storage module missing: $ModulePath" }
Import-Module -Name $ModulePath -Force

$Utf8 = New-Object System.Text.UTF8Encoding($false)
$RunRoot = Join-Path $FixtureParent ('storage-profile-tests-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($RunRoot)
$script:Checks = 0

function Write-FixtureFile([string] $Path, [string] $Content) {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    [System.IO.File]::WriteAllText($Path, $Content, $Utf8)
}

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Checks++
}

function Assert-Equal($Expected, $Actual, [string] $Message) {
    if ($Expected -cne $Actual) { throw "FAIL: $Message (expected '$Expected', got '$Actual')" }
    $script:Checks++
}

function Assert-BytesEqual([byte[]] $Expected, [byte[]] $Actual, [string] $Message) {
    Assert-True ([Convert]::ToBase64String($Expected) -ceq [Convert]::ToBase64String($Actual)) $Message
}

function Assert-Throws([scriptblock] $Action, [string] $Message) {
    $Thrown = $false
    try { & $Action | Out-Null } catch { $Thrown = $true }
    Assert-True $Thrown $Message
}

function New-FixtureEngine([string] $Name) {
    $Root = Join-Path $RunRoot $Name
    $TargetRules = Join-Path $Root 'Engine\Source\Programs\UnrealBuildTool\Configuration\TargetRules.cs'
    $ModuleRules = Join-Path $Root 'Engine\Source\Programs\UnrealBuildTool\Configuration\UEBuildModuleCPP.cs'
    $BuildVersion = Join-Path $Root 'Engine\Build\Build.version'
    Write-FixtureFile $TargetRules @'
public enum DebugInfoMode
{
    None = 0,
    Engine = 1 << 0,
    EnginePlugins = 1 << 1,
    Project = 1 << 2,
    ProjectPlugins = 1 << 3,
    EngineOnly = Engine | EnginePlugins,
    Full = Engine | EnginePlugins | Project | ProjectPlugins,
}
[XmlConfigFile(Category = "BuildConfiguration")]
public DebugInfoMode DebugInfo { get; set; } = DebugInfoMode.Full;
'@
    Write-FixtureFile $ModuleRules @'
if (!Target.bUsePDBFiles || !Target.Platform.IsInGroup(UnrealPlatformGroup.Microsoft))
{
    if (!Target.DebugInfo.HasFlag(DebugInfoMode.ProjectPlugins) && Rules.Plugin != null)
        Result.bCreateDebugInfo = false;
    else if (!Target.DebugInfo.HasFlag(DebugInfoMode.Project) && Rules.Plugin == null)
        Result.bCreateDebugInfo = false;
}
'@
    Write-FixtureFile $BuildVersion '{"MajorVersion":5,"MinorVersion":7,"PatchVersion":4}'
    return $Root
}

function New-FixtureProject([string] $Name, [string] $EngineRoot) {
    $Root = Join-Path $RunRoot $Name
    [void][System.IO.Directory]::CreateDirectory($Root)
    $ProjectFile = Join-Path $Root ($Name + '.uproject')
    Write-FixtureFile $ProjectFile '{"FileVersion":3}'
    Write-FixtureFile (Join-Path $Root ('Source\' + $Name + 'Editor.Target.cs')) @'
using UnrealBuildTool;
public class FixtureEditorTarget : TargetRules
{
    public FixtureEditorTarget(TargetInfo Target) : base(Target)
    {
        Type = TargetType.Editor;
    }
}
'@
    return $Root
}

$Engine = New-FixtureEngine 'engine'
$CloneA = New-FixtureProject 'cloneA' $Engine
$CloneB = New-FixtureProject 'cloneB' $Engine
$ConfigA = Join-Path $CloneA 'Saved\UnrealBuildTool\BuildConfiguration.xml'
$StateA = Join-Path $CloneA 'Saved\UnrealBuildTool\CkStorageProfile.json'
$ConfigB = Join-Path $CloneB 'Saved\UnrealBuildTool\BuildConfiguration.xml'
$StateB = Join-Path $CloneB 'Saved\UnrealBuildTool\CkStorageProfile.json'

try {
    # Read-only baseline and per-clone independence.
    $Before = Get-ProjectStorageStatus -Project $CloneA
    Assert-True (-not (Test-Path -LiteralPath $ConfigA)) 'baseline status created XML'
    Assert-True (-not (Test-Path -LiteralPath $StateA)) 'baseline status created state'
    Assert-True (-not (Test-Path -LiteralPath $ConfigB)) 'status touched another clone'

    $BaselineXml = '<?xml version="1.0" encoding="utf-8"?>' + "`r`n" +
        '<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration"><BuildConfiguration><bUseUnityBuild>false</bUseUnityBuild></BuildConfiguration></Configuration>' + "`r`n"
    Write-FixtureFile $ConfigA $BaselineXml
    $BaselineBytes = [System.IO.File]::ReadAllBytes($ConfigA)

    $Lean = Set-ProjectStorageProfile -Project $CloneA -Profile Lean -EngineRoot $Engine
    Assert-Equal 'PendingBuildVerification' $Lean.Status 'lean must request build verification'
    Assert-True (Test-Path -LiteralPath $StateA -PathType Leaf) 'lean state missing'
    Assert-True (Test-Path -LiteralPath $ConfigA -PathType Leaf) 'lean XML missing'
    $LeanXml = [System.IO.File]::ReadAllText($ConfigA)
    Assert-True ($LeanXml -match '<DebugInfo>EngineOnly</DebugInfo>') 'lean debug mode missing'
    Assert-True ($LeanXml -match '<bUseUnityBuild>false</bUseUnityBuild>') 'unrelated XML changed'
    Assert-True (-not (Test-Path -LiteralPath $ConfigB)) 'lean changed another clone XML'
    Assert-True (-not (Test-Path -LiteralPath $StateB)) 'lean changed another clone state'

    $OnceXml = [System.IO.File]::ReadAllBytes($ConfigA)
    $OnceState = [System.IO.File]::ReadAllBytes($StateA)
    Set-ProjectStorageProfile -Project $CloneA -Profile Lean -EngineRoot $Engine | Out-Null
    Assert-BytesEqual $OnceXml ([System.IO.File]::ReadAllBytes($ConfigA)) 'same profile rewrote XML'
    Assert-BytesEqual $OnceState ([System.IO.File]::ReadAllBytes($StateA)) 'same profile rewrote state'

    $Full = Set-ProjectStorageProfile -Project $CloneA -Profile Full -EngineRoot $Engine
    Assert-Equal 'PendingBuildVerification' $Full.Status 'full must request build verification'
    Assert-True ([System.IO.File]::ReadAllText($ConfigA) -match '<DebugInfo>Full</DebugInfo>') 'full debug mode missing'
    Set-ProjectStorageProfile -Project $CloneA -Profile Default -EngineRoot $Engine | Out-Null
    Assert-BytesEqual $BaselineBytes ([System.IO.File]::ReadAllBytes($ConfigA)) 'default failed exact byte restore'
    Assert-True (-not (Test-Path -LiteralPath $StateA)) 'default left managed state'

    # Rejection must not partly change the XML or state.
    $Malformed = '<Configuration><BuildConfiguration><DebugInfo>Full</DebugInfo>'
    Write-FixtureFile $ConfigA $Malformed
    $MalformedBytes = [System.IO.File]::ReadAllBytes($ConfigA)
    Assert-Throws { Set-ProjectStorageProfile -Project $CloneA -Profile Lean -EngineRoot $Engine } 'malformed XML accepted'
    Assert-BytesEqual $MalformedBytes ([System.IO.File]::ReadAllBytes($ConfigA)) 'malformed XML was mutated'
    Assert-True (-not (Test-Path -LiteralPath $StateA)) 'malformed XML created state'

    Write-FixtureFile $ConfigA $BaselineXml
    Write-FixtureFile $StateA '{broken json'
    $StateBytes = [System.IO.File]::ReadAllBytes($StateA)
    Assert-Throws { Set-ProjectStorageProfile -Project $CloneA -Profile Lean -EngineRoot $Engine } 'malformed state accepted'
    Assert-BytesEqual $BaselineBytes ([System.IO.File]::ReadAllBytes($ConfigA)) 'malformed state mutated XML'
    Assert-BytesEqual $StateBytes ([System.IO.File]::ReadAllBytes($StateA)) 'malformed state was mutated'

    $DuplicateDebugInfo = '<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration"><BuildConfiguration><DebugInfo>Full</DebugInfo><DebugInfo>EngineOnly</DebugInfo></BuildConfiguration></Configuration>'
    Write-FixtureFile $ConfigB $DuplicateDebugInfo
    $DuplicateBytes = [System.IO.File]::ReadAllBytes($ConfigB)
    Assert-Throws { Set-ProjectStorageProfile -Project $CloneB -Profile Lean -EngineRoot $Engine } 'duplicate DebugInfo accepted'
    Assert-BytesEqual $DuplicateBytes ([System.IO.File]::ReadAllBytes($ConfigB)) 'duplicate DebugInfo mutated XML'
    Assert-True (-not (Test-Path -LiteralPath $StateB)) 'duplicate DebugInfo created state'

    $DuplicateCategory = '<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration"><BuildConfiguration/><BuildConfiguration/></Configuration>'
    Write-FixtureFile $ConfigB $DuplicateCategory
    $CategoryBytes = [System.IO.File]::ReadAllBytes($ConfigB)
    Assert-Throws { Set-ProjectStorageProfile -Project $CloneB -Profile Lean -EngineRoot $Engine } 'duplicate BuildConfiguration accepted'
    Assert-BytesEqual $CategoryBytes ([System.IO.File]::ReadAllBytes($ConfigB)) 'duplicate BuildConfiguration mutated XML'
    Assert-True (-not (Test-Path -LiteralPath $StateB)) 'duplicate BuildConfiguration created state'

    # UBT matches literal XML names; a prefix with the same namespace is not equivalent.
    $PrefixedXmlCases = @(
        '<ubt:Configuration xmlns:ubt="https://www.unrealengine.com/BuildConfiguration"><ubt:BuildConfiguration/></ubt:Configuration>',
        '<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration" xmlns:ubt="https://www.unrealengine.com/BuildConfiguration"><ubt:BuildConfiguration/></Configuration>',
        '<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration" xmlns:ubt="https://www.unrealengine.com/BuildConfiguration"><BuildConfiguration><ubt:DebugInfo>Full</ubt:DebugInfo></BuildConfiguration></Configuration>'
    )
    foreach ($PrefixedXml in $PrefixedXmlCases) {
        Write-FixtureFile $ConfigB $PrefixedXml
        $PrefixedBytes = [IO.File]::ReadAllBytes($ConfigB)
        Assert-Throws { Set-ProjectStorageProfile -Project $CloneB -Profile Lean -EngineRoot $Engine } 'prefixed UBT XML name accepted'
        Assert-BytesEqual $PrefixedBytes ([IO.File]::ReadAllBytes($ConfigB)) 'prefixed UBT XML changed'
        Assert-True (-not (Test-Path -LiteralPath $StateB)) 'prefixed UBT XML created state'
    }

    $PdbConflict = '<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration"><BuildConfiguration><bUsePDBFiles>true</bUsePDBFiles></BuildConfiguration></Configuration>'
    Write-FixtureFile $ConfigB $PdbConflict
    $ConflictBytes = [System.IO.File]::ReadAllBytes($ConfigB)
    Assert-Throws { Set-ProjectStorageProfile -Project $CloneB -Profile Lean -EngineRoot $Engine } 'bUsePDBFiles conflict accepted'
    Assert-BytesEqual $ConflictBytes ([System.IO.File]::ReadAllBytes($ConfigB)) 'bUsePDBFiles conflict mutated XML'
    Assert-True (-not (Test-Path -LiteralPath $StateB)) 'bUsePDBFiles conflict created state'

    $OmitConflict = '<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration"><BuildConfiguration><bOmitPCDebugInfoInDevelopment>true</bOmitPCDebugInfoInDevelopment></BuildConfiguration></Configuration>'
    Write-FixtureFile $ConfigB $OmitConflict
    $OmitBytes = [System.IO.File]::ReadAllBytes($ConfigB)
    Assert-Throws { Set-ProjectStorageProfile -Project $CloneB -Profile Lean -EngineRoot $Engine } 'global debug omission accepted'
    Assert-BytesEqual $OmitBytes ([System.IO.File]::ReadAllBytes($ConfigB)) 'global debug omission mutated XML'
    Assert-True (-not (Test-Path -LiteralPath $StateB)) 'global debug omission created state'

    $OverrideProject = New-FixtureProject 'overrideProject' $Engine
    $OverrideTarget = Join-Path $OverrideProject 'Source\overrideProjectEditor.Target.cs'
    Write-FixtureFile $OverrideTarget 'public class OverrideProjectEditorTarget : TargetRules { public OverrideProjectEditorTarget(TargetInfo Target) : base(Target) { Type = TargetType.Editor; DebugInfo = DebugInfoMode.Full; } }'
    $OverrideConfig = Join-Path $OverrideProject 'Saved\UnrealBuildTool\BuildConfiguration.xml'
    $OverrideState = Join-Path $OverrideProject 'Saved\UnrealBuildTool\CkStorageProfile.json'
    Assert-Throws { Set-ProjectStorageProfile -Project $OverrideProject -Profile Lean -EngineRoot $Engine } 'Target.cs debug override accepted'
    Assert-True (-not (Test-Path -LiteralPath $OverrideConfig)) 'Target.cs override created XML'
    Assert-True (-not (Test-Path -LiteralPath $OverrideState)) 'Target.cs override created state'

    $UnsupportedEngine = New-FixtureEngine 'unsupportedEngine'
    Write-FixtureFile (Join-Path $UnsupportedEngine 'Engine\Build\Build.version') '{"MajorVersion":5,"MinorVersion":6,"PatchVersion":0}'
    $UnsupportedProject = New-FixtureProject 'unsupportedProject' $UnsupportedEngine
    Assert-Throws { Set-ProjectStorageProfile -Project $UnsupportedProject -Profile Lean -EngineRoot $UnsupportedEngine } 'unsupported engine accepted'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $UnsupportedProject 'Saved\UnrealBuildTool\BuildConfiguration.xml'))) 'unsupported engine created XML'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $UnsupportedProject 'Saved\UnrealBuildTool\CkStorageProfile.json'))) 'unsupported engine created state'

    $DriftProject = New-FixtureProject 'driftProject' $Engine
    $DriftConfig = Join-Path $DriftProject 'Saved\UnrealBuildTool\BuildConfiguration.xml'
    $DriftState = Join-Path $DriftProject 'Saved\UnrealBuildTool\CkStorageProfile.json'
    Set-ProjectStorageProfile -Project $DriftProject -Profile Lean -EngineRoot $Engine | Out-Null
    $DriftXml = [System.IO.File]::ReadAllText($DriftConfig) + "`r`n<!-- local edit -->"
    Write-FixtureFile $DriftConfig $DriftXml
    $DriftBytes = [System.IO.File]::ReadAllBytes($DriftConfig)
    $DriftStateBytes = [System.IO.File]::ReadAllBytes($DriftState)
    Assert-Throws { Set-ProjectStorageProfile -Project $DriftProject -Profile Default -EngineRoot $Engine } 'managed XML drift accepted'
    Assert-BytesEqual $DriftBytes ([System.IO.File]::ReadAllBytes($DriftConfig)) 'drift rejection changed XML'
    Assert-BytesEqual $DriftStateBytes ([System.IO.File]::ReadAllBytes($DriftState)) 'drift rejection changed state'

    $Utf16Project = New-FixtureProject 'utf16Project' $Engine
    $Utf16Config = Join-Path $Utf16Project 'Saved\UnrealBuildTool\BuildConfiguration.xml'
    $Utf16Text = '<?xml version="1.0" encoding="utf-16"?>' + "`r`n" +
        '<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration"><BuildConfiguration><bUseUnityBuild>false</bUseUnityBuild></BuildConfiguration></Configuration>' + "`r`n"
    $Utf16Bytes = [byte[]]([Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes($Utf16Text))
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Utf16Config))
    [IO.File]::WriteAllBytes($Utf16Config, $Utf16Bytes)
    Set-ProjectStorageProfile -Project $Utf16Project -Profile Lean -EngineRoot $Engine | Out-Null
    $Utf16Status = Get-ProjectStorageStatus -Project $Utf16Project
    Assert-Equal 'Lean' $Utf16Status.Profile 'UTF-16 source XML prevented Lean status'
    Assert-Equal 'PendingBuildVerification' $Utf16Status.Status 'UTF-16 Lean status incorrect'
    Set-ProjectStorageProfile -Project $Utf16Project -Profile Default -EngineRoot $Engine | Out-Null
    Assert-BytesEqual $Utf16Bytes ([IO.File]::ReadAllBytes($Utf16Config)) 'UTF-16 baseline not restored byte-exactly'

    $CorruptProject = New-FixtureProject 'corruptProject' $Engine
    $CorruptConfig = Join-Path $CorruptProject 'Saved\UnrealBuildTool\BuildConfiguration.xml'
    $CorruptState = Join-Path $CorruptProject 'Saved\UnrealBuildTool\CkStorageProfile.json'
    Write-FixtureFile $CorruptConfig $BaselineXml
    Set-ProjectStorageProfile -Project $CorruptProject -Profile Lean -EngineRoot $Engine | Out-Null
    $StateObject = [IO.File]::ReadAllText($CorruptState) | ConvertFrom-Json
    $StateObject.OriginalXmlBase64 = ''
    Write-FixtureFile $CorruptState ($StateObject | ConvertTo-Json -Depth 5)
    $CorruptXmlBytes = [IO.File]::ReadAllBytes($CorruptConfig)
    $CorruptStateBytes = [IO.File]::ReadAllBytes($CorruptState)
    Assert-Throws { Set-ProjectStorageProfile -Project $CorruptProject -Profile Default -EngineRoot $Engine } 'corrupt baseline hash accepted'
    Assert-BytesEqual $CorruptXmlBytes ([IO.File]::ReadAllBytes($CorruptConfig)) 'corrupt baseline hash changed XML'
    Assert-BytesEqual $CorruptStateBytes ([IO.File]::ReadAllBytes($CorruptState)) 'corrupt baseline hash changed state'
    $StateObject.OriginalXmlHash = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    Write-FixtureFile $CorruptState ($StateObject | ConvertTo-Json -Depth 5)
    $CorruptStateBytes = [IO.File]::ReadAllBytes($CorruptState)
    Assert-Throws { Set-ProjectStorageProfile -Project $CorruptProject -Profile Default -EngineRoot $Engine } 'empty baseline with matching hash accepted'
    Assert-BytesEqual $CorruptXmlBytes ([IO.File]::ReadAllBytes($CorruptConfig)) 'empty baseline changed XML'
    Assert-BytesEqual $CorruptStateBytes ([IO.File]::ReadAllBytes($CorruptState)) 'empty baseline changed state'

    $LinkerProject = New-FixtureProject 'linkerProject' $Engine
    $LinkerConfig = Join-Path $LinkerProject 'Saved\UnrealBuildTool\BuildConfiguration.xml'
    $LinkerState = Join-Path $LinkerProject 'Saved\UnrealBuildTool\CkStorageProfile.json'
    $LinkerXml = '<Configuration xmlns="https://www.unrealengine.com/BuildConfiguration"><WindowsPlatform><bNoLinkerDebugInfo>true</bNoLinkerDebugInfo></WindowsPlatform></Configuration>'
    Write-FixtureFile $LinkerConfig $LinkerXml
    $LinkerBytes = [IO.File]::ReadAllBytes($LinkerConfig)
    Assert-Throws { Set-ProjectStorageProfile -Project $LinkerProject -Profile Lean -EngineRoot $Engine } 'WindowsPlatform linker-debug override accepted'
    Assert-BytesEqual $LinkerBytes ([IO.File]::ReadAllBytes($LinkerConfig)) 'linker-debug override changed XML'
    Assert-True (-not (Test-Path -LiteralPath $LinkerState)) 'linker-debug override created state'

    foreach ($TargetOverride in @('WindowsPlatform.bNoLinkerDebugInfo = true;', 'DebugInfoLineTablesOnlyModules.Add("Foo");', 'DebugInfoLineTablesOnlyPlugins.Add("Foo");')) {
        $OverrideName = 'targetConflict' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $TargetProject = New-FixtureProject $OverrideName $Engine
        $TargetFile = Join-Path $TargetProject ('Source\' + $OverrideName + 'Editor.Target.cs')
        Write-FixtureFile $TargetFile ('public class ConflictTarget : TargetRules { public ConflictTarget(TargetInfo Target) : base(Target) { Type = TargetType.Editor; ' + $TargetOverride + ' } }')
        Assert-Throws { Set-ProjectStorageProfile -Project $TargetProject -Profile Lean -EngineRoot $Engine } "target override accepted: $TargetOverride"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $TargetProject 'Saved\UnrealBuildTool\BuildConfiguration.xml'))) "target override created XML: $TargetOverride"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $TargetProject 'Saved\UnrealBuildTool\CkStorageProfile.json'))) "target override created state: $TargetOverride"
    }

    $CaseProject = New-FixtureProject 'caseProject' $Engine
    $CaseStatus = Set-ProjectStorageProfile -Project $CaseProject -Profile lean -EngineRoot $Engine
    Assert-Equal 'Lean' $CaseStatus.Profile 'lowercase profile was not canonicalized'
    Assert-Equal 'Lean' (([IO.File]::ReadAllText((Join-Path $CaseProject 'Saved\UnrealBuildTool\CkStorageProfile.json')) | ConvertFrom-Json).Profile) 'lowercase persisted to managed state'

    $WhatIfProject = New-FixtureProject 'whatIfProject' $Engine
    Set-ProjectStorageProfile -Project $WhatIfProject -Profile Lean -EngineRoot $Engine -WhatIf | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $WhatIfProject 'Saved\UnrealBuildTool\BuildConfiguration.xml'))) 'WhatIf created XML'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $WhatIfProject 'Saved\UnrealBuildTool\CkStorageProfile.json'))) 'WhatIf created state'

    $EnvProject = New-FixtureProject 'envProject' $Engine
    $EnvName = 'UnrealBuildTool_BuildConfiguration__DebugInfo'
    $PriorEnv = [Environment]::GetEnvironmentVariable($EnvName, 'Process')
    try {
        [Environment]::SetEnvironmentVariable($EnvName, 'Full', 'Process')
        Assert-Throws { Set-ProjectStorageProfile -Project $EnvProject -Profile Lean -EngineRoot $Engine } 'environment debug override accepted'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $EnvProject 'Saved\UnrealBuildTool\BuildConfiguration.xml'))) 'environment override created XML'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $EnvProject 'Saved\UnrealBuildTool\CkStorageProfile.json'))) 'environment override created state'
    } finally { [Environment]::SetEnvironmentVariable($EnvName, $PriorEnv, 'Process') }

    # Fail the second atomic write in memory, then let the module's rollback writes run.
    $RollbackProject = New-FixtureProject 'rollbackProject' $Engine
    $RollbackConfig = Join-Path $RollbackProject 'Saved\UnrealBuildTool\BuildConfiguration.xml'
    $RollbackState = Join-Path $RollbackProject 'Saved\UnrealBuildTool\CkStorageProfile.json'
    Write-FixtureFile $RollbackConfig $BaselineXml
    $RollbackBytes = [IO.File]::ReadAllBytes($RollbackConfig)
    $StorageModule = Get-Module ProjectStorage
    Assert-True ($null -ne $StorageModule) 'imported module unavailable for rollback injection'
    & $StorageModule {
        $script:OriginalStorageAtomic = (Get-Item -LiteralPath Function:Write-StorageAtomic).ScriptBlock
        $script:InjectedStorageWriteCount = 0
        Set-Item -Path Function:script:Write-StorageAtomic -Value {
            param([string]$Path, [byte[]]$Bytes)
            $script:InjectedStorageWriteCount++
            if ($script:InjectedStorageWriteCount -eq 2) { throw 'Injected second write failure' }
            & $script:OriginalStorageAtomic -Path $Path -Bytes $Bytes
        }
    }
    try {
        Assert-Throws { Set-ProjectStorageProfile -Project $RollbackProject -Profile Lean -EngineRoot $Engine } 'injected second write did not fail'
    } finally {
        & $StorageModule {
            Set-Item -Path Function:script:Write-StorageAtomic -Value $script:OriginalStorageAtomic
            Remove-Variable -Scope Script -Name OriginalStorageAtomic,InjectedStorageWriteCount -ErrorAction SilentlyContinue
        }
    }
    Assert-BytesEqual $RollbackBytes ([IO.File]::ReadAllBytes($RollbackConfig)) 'failed second write did not restore baseline XML'
    Assert-True (-not (Test-Path -LiteralPath $RollbackState)) 'failed second write left managed state'

    $StatusFailureProject = New-FixtureProject 'statusFailureProject' $Engine
    $StatusFailureXml = Join-Path $StatusFailureProject 'Saved\UnrealBuildTool\BuildConfiguration.xml'
    $StatusFailureState = Join-Path $StatusFailureProject 'Saved\UnrealBuildTool\CkStorageProfile.json'
    Write-FixtureFile $StatusFailureXml $BaselineXml
    $StatusFailureBytes = [IO.File]::ReadAllBytes($StatusFailureXml)
    & $StorageModule {
        $script:OriginalStorageStatus = (Get-Item -LiteralPath Function:Get-ProjectStorageStatus).ScriptBlock
        $script:InjectedStatusCount = 0
        Set-Item -Path Function:script:Get-ProjectStorageStatus -Value {
            param([string]$Project)
            $script:InjectedStatusCount++
            if ($script:InjectedStatusCount -eq 1) { throw 'Injected post-write status failure' }
            & $script:OriginalStorageStatus -Project $Project
        }
    }
    try {
        Assert-Throws { Set-ProjectStorageProfile -Project $StatusFailureProject -Profile Lean -EngineRoot $Engine } 'injected post-write status did not fail'
    } finally {
        & $StorageModule {
            Set-Item -Path Function:script:Get-ProjectStorageStatus -Value $script:OriginalStorageStatus
            Remove-Variable -Scope Script -Name OriginalStorageStatus,InjectedStatusCount -ErrorAction SilentlyContinue
        }
    }
    Assert-BytesEqual $StatusFailureBytes ([IO.File]::ReadAllBytes($StatusFailureXml)) 'post-write status failure did not restore XML'
    Assert-True (-not (Test-Path -LiteralPath $StatusFailureState)) 'post-write status failure left managed state'

    $MissingProject = Join-Path $RunRoot 'missingProject'
    [void][System.IO.Directory]::CreateDirectory($MissingProject)
    Assert-Throws { Resolve-StorageProject -Project $MissingProject } 'missing uproject accepted'
    $AmbiguousProject = Join-Path $RunRoot 'ambiguousProject'
    [void][System.IO.Directory]::CreateDirectory($AmbiguousProject)
    Write-FixtureFile (Join-Path $AmbiguousProject 'One.uproject') '{}'
    Write-FixtureFile (Join-Path $AmbiguousProject 'Two.uproject') '{}'
    Assert-Throws { Resolve-StorageProject -Project $AmbiguousProject } 'ambiguous uproject accepted'

    Assert-Throws { Assert-StoragePath -Root $CloneA -Path (Join-Path $RunRoot 'outside.txt') } 'external path accepted'
    $Outside = Join-Path $RunRoot 'outside'
    [void][System.IO.Directory]::CreateDirectory($Outside)
    $Link = Join-Path $CloneB 'escape-link'
    try {
        New-Item -ItemType Junction -Path $Link -Target $Outside -ErrorAction Stop | Out-Null
        Assert-Throws { Assert-StoragePath -Root $CloneB -Path (Join-Path $Link 'file.txt') } 'junction escape accepted'
    } catch {
        # If junction creation is unavailable, retain the lexical escape assertion.
        if (Test-Path -LiteralPath $Link) { throw }
        Write-Host 'SKIP: junction creation unavailable in this shell'
    }
}
finally {
    Write-Host "Fixture retained: $RunRoot"
}

Write-Host "PASS: $script:Checks storage profile assertions"
