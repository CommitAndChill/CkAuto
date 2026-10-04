# Per-project UBT profiles. Windows PowerShell 5.1 and PowerShell 7 compatible.
Set-StrictMode -Version 2.0
$script:ConfigNamespace = 'https://www.unrealengine.com/BuildConfiguration'

function Assert-StoragePath {
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$Path)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not ($fullPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Path is outside the selected project: $fullPath"
    }
    # Check ancestors as well as the leaf; a junction in Saved must never redirect writes.
    $cursor = $fullPath
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if (((Get-Item -LiteralPath $cursor -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not supported for project storage paths: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Resolve-StorageProject {
    param([Parameter(Mandatory=$true)][string]$Project)
    $item = Get-Item -LiteralPath $Project -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        $rootPath = $item.FullName
        Assert-StoragePath -Root $rootPath -Path $rootPath
        $files = @(Get-ChildItem -LiteralPath $rootPath -Filter '*.uproject' -File -Force -ErrorAction Stop)
        if ($files.Count -ne 1) { throw "Select exactly one .uproject file; directory contains $($files.Count): $rootPath" }
        $projectFile = $files[0].FullName
    } else {
        if ($item.Extension -ine '.uproject') { throw "Expected a .uproject file: $($item.FullName)" }
        $projectFile = $item.FullName
        $rootPath = $item.DirectoryName
    }
    Assert-StoragePath -Root $rootPath -Path $projectFile
    $manifest = [IO.File]::ReadAllText($projectFile) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $manifest -or $manifest -is [array] -or $manifest -is [string] -or $manifest -is [ValueType]) {
        throw "Invalid project manifest: $projectFile"
    }
    return [pscustomobject]@{ ProjectFile=$projectFile; Root=$rootPath; Manifest=$manifest }
}

function Read-StorageXml {
    param([string]$Path)
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Path, $settings)
    try {
        $document = New-Object Xml.XmlDocument
        $document.PreserveWhitespace = $true
        $document.XmlResolver = $null
        $document.Load($reader)
    } finally { $reader.Dispose() }
    if ($document.DocumentElement.Name -cne 'Configuration' -or $document.DocumentElement.NamespaceURI -ne $script:ConfigNamespace) {
        throw "Invalid UBT Configuration root or namespace: $Path"
    }
    return ,$document
}

function ConvertTo-StorageXmlBytes {
    param([Xml.XmlDocument]$Document)
    # Serialize through XmlWriter so an original UTF-16 declaration cannot label UTF-8 bytes.
    $stream = New-Object IO.MemoryStream
    $settings = New-Object Xml.XmlWriterSettings
    $settings.Encoding = New-Object Text.UTF8Encoding($false)
    $settings.Indent = $false
    $writer = [Xml.XmlWriter]::Create($stream, $settings)
    try { $Document.Save($writer); $writer.Flush(); return ,$stream.ToArray() }
    finally { $writer.Dispose(); $stream.Dispose() }
}

function Get-StorageElement {
    param([Xml.XmlNode]$Parent, [string]$Name)
    $nodes = @($Parent.ChildNodes | Where-Object { $_ -is [Xml.XmlElement] -and $_.LocalName -eq $Name })
    if ($nodes.Count -gt 1) { throw "Duplicate UBT setting/category: $Name" }
    if ($nodes.Count -eq 1) {
        if ($nodes[0].NamespaceURI -ne $script:ConfigNamespace -or $nodes[0].Name -cne $Name) { throw "Invalid namespace or prefixed UBT setting: $Name" }
        return $nodes[0]
    }
    return $null
}

function Get-StoragePaths {
    param($ResolvedProject)
    $directory = Join-Path $ResolvedProject.Root 'Saved\UnrealBuildTool'
    $xmlPath = Join-Path $directory 'BuildConfiguration.xml'
    $statePath = Join-Path $directory 'CkStorageProfile.json'
    Assert-StoragePath -Root $ResolvedProject.Root -Path $xmlPath
    Assert-StoragePath -Root $ResolvedProject.Root -Path $statePath
    return [pscustomobject]@{ Directory=$directory; Xml=$xmlPath; State=$statePath }
}

function Get-StorageHash {
    param([byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Read-StorageState {
    param($ResolvedProject, $Paths)
    if (-not (Test-Path -LiteralPath $Paths.State)) { return $null }
    $state = [IO.File]::ReadAllText($Paths.State) | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $state -or $state -is [array]) { throw 'Invalid storage profile state.' }
    foreach ($required in @('SchemaVersion','ProjectName','Profile','OriginalXmlExists','OriginalXmlBase64','OriginalXmlHash','ManagedXmlHash')) {
        if (-not ($state.PSObject.Properties.Name -contains $required)) { throw "Storage state is missing $required." }
    }
    if ($state.SchemaVersion -ne 1 -or $state.ProjectName -cne [IO.Path]::GetFileName($ResolvedProject.ProjectFile) -or
        @('Lean','Full') -cnotcontains $state.Profile -or $state.OriginalXmlExists -isnot [bool] -or
        $state.ManagedXmlHash -notmatch '^[a-f0-9]{64}$') { throw 'Invalid or mismatched storage profile state.' }
    $originalBytes = [Convert]::FromBase64String($state.OriginalXmlBase64)
    if ($state.OriginalXmlHash -cne (Get-StorageHash -Bytes $originalBytes) -or
        (-not $state.OriginalXmlExists -and $originalBytes.Length -ne 0)) { throw 'Storage profile baseline is corrupt.' }
    if ($state.OriginalXmlExists) {
        $stream = New-Object IO.MemoryStream(,$originalBytes)
        $readerSettings = New-Object Xml.XmlReaderSettings
        $readerSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $readerSettings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($stream, $readerSettings)
        try {
            $baselineDocument = New-Object Xml.XmlDocument
            $baselineDocument.XmlResolver = $null
            $baselineDocument.Load($reader)
            if ($baselineDocument.DocumentElement.Name -cne 'Configuration' -or $baselineDocument.DocumentElement.NamespaceURI -ne $script:ConfigNamespace) {
                throw 'Storage profile baseline is not a UBT configuration.'
            }
        } finally { $reader.Dispose(); $stream.Dispose() }
    }
    if (-not (Test-Path -LiteralPath $Paths.Xml -PathType Leaf)) { throw 'Managed UBT configuration is missing; restore it before changing profiles.' }
    $currentHash = Get-StorageHash -Bytes ([IO.File]::ReadAllBytes($Paths.Xml))
    if ($currentHash -cne $state.ManagedXmlHash) {
        throw 'UBT configuration changed after the profile was set. Preserve/reconcile those edits before changing or restoring the profile.'
    }
    return $state
}

function Get-ProjectStorageStatus {
    param([Parameter(Mandatory=$true)][string]$Project)
    $resolved = Resolve-StorageProject -Project $Project
    $paths = Get-StoragePaths -ResolvedProject $resolved
    $state = Read-StorageState -ResolvedProject $resolved -Paths $paths
    $debugInfo = $null
    if (Test-Path -LiteralPath $paths.Xml) {
        $document = Read-StorageXml -Path $paths.Xml
        $category = Get-StorageElement -Parent $document.DocumentElement -Name 'BuildConfiguration'
        if ($category) {
            $setting = Get-StorageElement -Parent $category -Name 'DebugInfo'
            if ($setting) { $debugInfo = $setting.InnerText }
        }
    }
    $profile = 'Default'
    $status = 'Unmanaged'
    if ($state) { $profile=$state.Profile; $status='PendingBuildVerification' }
    return [pscustomobject]@{
        ProjectFile=$resolved.ProjectFile; Profile=$profile; Status=$status
        ConfigPath=$paths.Xml; DebugInfo=$debugInfo
        RecommendedConfiguration=$(if ($profile -eq 'Lean') { 'Development' } else { $null })
        Note='Configured defaults only. Target rules, command-line arguments and environment can override UBT XML; verify the next build actions.'
    }
}

function Resolve-StorageEngine {
    param($ResolvedProject, [string]$EngineRoot)
    if ($EngineRoot) { return (Get-Item -LiteralPath $EngineRoot -ErrorAction Stop).FullName }
    if (-not ($ResolvedProject.Manifest.PSObject.Properties.Name -contains 'EngineAssociation')) { throw 'Project has no EngineAssociation; supply -EngineRoot.' }
    $association = [string]$ResolvedProject.Manifest.EngineAssociation
    if ([string]::IsNullOrWhiteSpace($association)) { throw 'Project has no EngineAssociation; supply -EngineRoot.' }
    $enginePath = $null
    if ($association -match '^\{[0-9a-fA-F-]+\}$') {
        foreach ($registry in @('HKCU:\Software\Epic Games\Unreal Engine\Builds','HKLM:\SOFTWARE\Epic Games\Unreal Engine\Builds')) {
            if (Test-Path -LiteralPath $registry) {
                $builds = Get-ItemProperty -LiteralPath $registry -ErrorAction Stop
                if ($builds.PSObject.Properties.Name -contains $association) { $enginePath=$builds.$association; break }
            }
        }
    } elseif ($association -match '^\d+\.\d+$') {
        $registry = "HKLM:\SOFTWARE\EpicGames\Unreal Engine\$association"
        if (Test-Path -LiteralPath $registry) { $enginePath=(Get-ItemProperty -LiteralPath $registry -ErrorAction Stop).InstalledDirectory }
    } elseif ([IO.Path]::IsPathRooted($association)) { $enginePath=$association }
    else { $enginePath=Join-Path $ResolvedProject.Root $association }
    if (-not $enginePath) { throw "Cannot resolve engine '$association'; supply -EngineRoot." }
    return (Get-Item -LiteralPath $enginePath -ErrorAction Stop).FullName
}

function Assert-StorageCapability {
    param([string]$EngineRoot)
    $versionPath = Join-Path $EngineRoot 'Engine\Build\Build.version'
    $version = [IO.File]::ReadAllText($versionPath) | ConvertFrom-Json -ErrorAction Stop
    if ($version.MajorVersion -ne 5 -or $version.MinorVersion -lt 7) { throw 'Storage profiles currently require UE 5.7+ with the verified EngineOnly debug-info API.' }
    $sourceRoot = Join-Path $EngineRoot 'Engine\Source\Programs\UnrealBuildTool'
    $rules = [IO.File]::ReadAllText((Join-Path $sourceRoot 'Configuration\TargetRules.cs'))
    $module = [IO.File]::ReadAllText((Join-Path $sourceRoot 'Configuration\UEBuildModuleCPP.cs'))
    if ($rules -notmatch 'enum\s+DebugInfoMode' -or $rules -notmatch '\bEngineOnly\s*=' -or
        $rules -notmatch '\bDebugInfoMode\s+DebugInfo\b' -or $rules -notmatch 'XmlConfigFile' -or
        $module -notmatch 'Target\.DebugInfo\.HasFlag\(DebugInfoMode\.ProjectPlugins\)' -or
        $module -notmatch 'Target\.DebugInfo\.HasFlag\(DebugInfoMode\.Project\)') {
        throw 'Engine lacks the verified project-scoped debug-info API. No configuration was changed.'
    }
}

function Assert-StorageLeanPrerequisites {
    param($ResolvedProject, [string]$EngineRoot, $Paths)
    # These flags can bypass the project-only filter or change shared engine debug output.
    $unsafeSettings = @('bUsePDBFiles','bOmitPCDebugInfoInDevelopment','bSupportEditAndContinue')
    $configPaths = @(
        (Join-Path $EngineRoot 'Engine\Restricted\NotForLicensees\Programs\UnrealBuildTool\BuildConfiguration.xml'),
        (Join-Path $EngineRoot 'Engine\Saved\UnrealBuildTool\BuildConfiguration.xml'))
    foreach ($folder in @('CommonApplicationData','ApplicationData','LocalApplicationData','MyDocuments')) {
        $specialFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::$folder)
        if ($specialFolder) { $configPaths += Join-Path $specialFolder 'Unreal Engine\UnrealBuildTool\BuildConfiguration.xml' }
    }
    $configPaths += $Paths.Xml
    $effective = @{}
    foreach ($configPath in $configPaths) {
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { continue }
        $document = Read-StorageXml -Path $configPath
        $category = Get-StorageElement -Parent $document.DocumentElement -Name 'BuildConfiguration'
        if ($category) {
            foreach ($key in $unsafeSettings + @('DebugInfo','DebugInfoLineTablesOnly')) {
                $element = Get-StorageElement -Parent $category -Name $key
                if ($element) { $effective[$key]=$element.InnerText.Trim() }
            }
        }
        $windowsCategory = Get-StorageElement -Parent $document.DocumentElement -Name 'WindowsPlatform'
        if ($windowsCategory) {
            $noLinkerInfo = Get-StorageElement -Parent $windowsCategory -Name 'bNoLinkerDebugInfo'
            if ($noLinkerInfo) { $effective['bNoLinkerDebugInfo']=$noLinkerInfo.InnerText.Trim() }
        }
    }
    foreach ($key in $unsafeSettings) {
        if ($effective.ContainsKey($key) -and $effective[$key] -ine 'false') { throw "Lean requires $key=false; existing UBT configuration uses '$($effective[$key])'." }
    }
    if ($effective.ContainsKey('DebugInfo') -and @('Full','EngineOnly') -inotcontains $effective['DebugInfo']) {
        throw "Lean will not replace existing engine debug policy '$($effective['DebugInfo'])'. Restore Full engine symbols first."
    }
    if ($effective.ContainsKey('DebugInfoLineTablesOnly') -and $effective['DebugInfoLineTablesOnly'] -ine 'None') {
        throw 'Lean requires DebugInfoLineTablesOnly=None; reconcile the existing debug policy first.'
    }
    if ($effective.ContainsKey('bNoLinkerDebugInfo') -and $effective['bNoLinkerDebugInfo'] -ine 'false') {
        throw 'Lean retains linker PDBs; reconcile bNoLinkerDebugInfo before selecting this profile.'
    }
    foreach ($variable in [Environment]::GetEnvironmentVariables().Keys) {
        if ([string]$variable -match '^UnrealBuildTool_(BuildConfiguration__(DebugInfo.*|bUsePDBFiles|bOmitPCDebugInfoInDevelopment|bSupportEditAndContinue|bForceDebugInfo)|WindowsPlatform__bNoLinkerDebugInfo)$') {
            throw "Environment override prevents a reliable clone-local profile: $variable"
        }
    }
    # Do not try to evaluate C# target rules. Reject known overrides and report remaining build validation separately.
    $sources = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    foreach ($subdirectory in @('Source','Plugins')) {
        $sourcePath = Join-Path $ResolvedProject.Root $subdirectory
        if (Test-Path -LiteralPath $sourcePath -PathType Container) {
            Assert-StoragePath -Root $ResolvedProject.Root -Path $sourcePath
            $sources.Push([IO.DirectoryInfo]::new($sourcePath))
        }
    }
    while ($sources.Count -gt 0) {
        foreach ($entry in $sources.Pop().EnumerateFileSystemInfos()) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Cannot validate target overrides through reparse point: $($entry.FullName)" }
            if ($entry -is [IO.DirectoryInfo]) {
                if (@('.git','Binaries','Intermediate','Saved','Content') -inotcontains $entry.Name) { $sources.Push($entry) }
            } elseif ($entry.Name -match '(?i)\.(Target|Build)\.cs$') {
                $text = [IO.File]::ReadAllText($entry.FullName)
                $text = [regex]::Replace($text, '(?s)/\*.*?\*/|(?m)//[^\r\n]*', '')
                if ($text -match '\b(DebugInfo|DebugInfoLineTablesOnly|bUsePDBFiles|bOmitPCDebugInfoInDevelopment|bSupportEditAndContinue|bForceDebugInfo|bNoLinkerDebugInfo)\s*=' -or
                    $text -match '\bDebugInfoLineTablesOnly(Modules|Plugins)\b') {
                    throw "Target/build rules explicitly override debug policy: $($entry.FullName). Reconcile this before selecting Lean."
                }
            }
        }
    }
}

function Write-StorageAtomic {
    param([string]$Path, [byte[]]$Bytes)
    $temporary = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Set-ProjectStorageProfile {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory=$true)][string]$Project,
        [Parameter(Mandatory=$true)][ValidateSet('Lean','Full','Default')][string]$Profile,
        [string]$EngineRoot
    )
    $Profile = switch ($Profile.ToLowerInvariant()) { 'lean' { 'Lean' }; 'full' { 'Full' }; 'default' { 'Default' } }
    $resolved = Resolve-StorageProject -Project $Project
    $paths = Get-StoragePaths -ResolvedProject $resolved
    $mutexName = 'Local\CkStorageProfile_' + (Get-StorageHash -Bytes ([Text.Encoding]::UTF8.GetBytes($resolved.ProjectFile.ToLowerInvariant())))
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    $acquired = $false
    try {
        try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
        if (-not $acquired) { throw 'Another profile operation is running for this project.' }
        $state = Read-StorageState -ResolvedProject $resolved -Paths $paths
        if ($Profile -eq 'Default' -and -not $state) { return Get-ProjectStorageStatus -Project $resolved.ProjectFile }
        if ($Profile -ne 'Default') {
            $engine = Resolve-StorageEngine -ResolvedProject $resolved -EngineRoot $EngineRoot
            Assert-StorageCapability -EngineRoot $engine
            if ($Profile -eq 'Lean') { Assert-StorageLeanPrerequisites -ResolvedProject $resolved -EngineRoot $engine -Paths $paths }
        }
        if ($state -and $state.Profile -eq $Profile) { return Get-ProjectStorageStatus -Project $resolved.ProjectFile }
        $xmlExists = [IO.File]::Exists($paths.Xml)
        $stateExists = [IO.File]::Exists($paths.State)
        $oldXml = [byte[]]@()
        $oldState = [byte[]]@()
        if ($xmlExists) { $oldXml=[IO.File]::ReadAllBytes($paths.Xml) }
        if ($stateExists) { $oldState=[IO.File]::ReadAllBytes($paths.State) }
        if ($Profile -eq 'Default') {
            if (-not $PSCmdlet.ShouldProcess($resolved.ProjectFile, 'Restore the exact UBT configuration saved before profile selection')) { return }
            try {
                if ($state.OriginalXmlExists) { Write-StorageAtomic -Path $paths.Xml -Bytes ([Convert]::FromBase64String($state.OriginalXmlBase64)) }
                else { [IO.File]::Delete($paths.Xml) }
                [IO.File]::Delete($paths.State)
                $result = Get-ProjectStorageStatus -Project $resolved.ProjectFile
            } catch {
                Write-StorageAtomic -Path $paths.Xml -Bytes $oldXml
                if ($stateExists) { Write-StorageAtomic -Path $paths.State -Bytes $oldState }
                throw
            }
        } else {
            if ($xmlExists) { $document=Read-StorageXml -Path $paths.Xml }
            else {
                $document = New-Object Xml.XmlDocument
                $document.AppendChild($document.CreateElement('Configuration', $script:ConfigNamespace)) | Out-Null
            }
            $category=Get-StorageElement -Parent $document.DocumentElement -Name 'BuildConfiguration'
            if (-not $category) {
                $category=$document.CreateElement('BuildConfiguration', $script:ConfigNamespace)
                $document.DocumentElement.AppendChild($category) | Out-Null
            }
            $element=Get-StorageElement -Parent $category -Name 'DebugInfo'
            if (-not $element) {
                $element=$document.CreateElement('DebugInfo', $script:ConfigNamespace)
                $category.AppendChild($element) | Out-Null
            }
            $element.InnerText=$(if ($Profile -eq 'Lean') { 'EngineOnly' } else { 'Full' })
            $newXml=ConvertTo-StorageXmlBytes -Document $document
            if (-not $state) {
                $state=[pscustomobject]@{SchemaVersion=1;ProjectName=[IO.Path]::GetFileName($resolved.ProjectFile);Profile=$Profile;
                    OriginalXmlExists=$xmlExists;OriginalXmlBase64=[Convert]::ToBase64String($oldXml);OriginalXmlHash=(Get-StorageHash -Bytes $oldXml);ManagedXmlHash=''}
            }
            $state.Profile=$Profile
            $state.ManagedXmlHash=Get-StorageHash -Bytes $newXml
            $newState=[Text.Encoding]::UTF8.GetBytes(($state | ConvertTo-Json -Depth 5))
            if (-not $PSCmdlet.ShouldProcess($resolved.ProjectFile, "Set $Profile profile in project-local UBT configuration")) { return }
            [IO.Directory]::CreateDirectory($paths.Directory) | Out-Null
            Assert-StoragePath -Root $resolved.Root -Path $paths.Xml
            Assert-StoragePath -Root $resolved.Root -Path $paths.State
            try {
                # Persist the recovery snapshot before changing the build configuration.
                Write-StorageAtomic -Path $paths.State -Bytes $newState
                Write-StorageAtomic -Path $paths.Xml -Bytes $newXml
                $result = Get-ProjectStorageStatus -Project $resolved.ProjectFile
            } catch {
                if ($xmlExists) { Write-StorageAtomic -Path $paths.Xml -Bytes $oldXml } else { [IO.File]::Delete($paths.Xml) }
                if ($stateExists) { Write-StorageAtomic -Path $paths.State -Bytes $oldState } else { [IO.File]::Delete($paths.State) }
                throw
            }
        }
        return $result
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

Export-ModuleMember -Function Resolve-StorageProject, Assert-StoragePath, Get-ProjectStorageStatus, Set-ProjectStorageProfile
