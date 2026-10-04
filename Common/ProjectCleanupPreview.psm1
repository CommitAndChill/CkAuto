Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'ProjectStorage.psm1') -ErrorAction Stop

$script:GeneratedExtensions = @('.pdb', '.dll', '.exe', '.lib', '.exp', '.obj', '.pch', '.res', '.modules', '.target', '.ilk', '.ipdb', '.iobj', '.json')
$script:KnownConfigurations = @('DebugGame', 'Debug', 'Test', 'Shipping')
$script:DiscoveryExclusions = @('.git', 'Binaries', 'Intermediate', 'Source', 'Content', 'Saved', 'DerivedDataCache', 'DDC', 'Engine')

function Get-ProjectCleanupPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Project,

        [ValidateSet('DebugGame', 'Debug', 'Test', 'Shipping')]
        [string[]] $Configuration = @('DebugGame')
    )

    if ($null -eq $Configuration -or $Configuration.Count -eq 0) {
        throw 'At least one configuration is required.'
    }

    $resolved = Resolve-StorageProject -Project $Project
    $root = $resolved.Root
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    $rootPrefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    $projectFile = $resolved.ProjectFile
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Configuration) {
        if ($script:KnownConfigurations -notcontains $name) {
            throw "Unsupported configuration: $name"
        }
        [void] $wanted.Add($name)
    }

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $totals = @{ Skipped = 0; Bytes = [long] 0 }

    function Test-ReparsePoint([System.IO.FileSystemInfo] $entry) {
        return (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }

    function Assert-LexicalProjectPath([string] $path) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        if (-not ($fullPath.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Path is outside the selected project: $fullPath"
        }
    }

    function Get-Children([string] $directory) {
        Assert-StoragePath -Root $root -Path $directory
        return @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
    }

    function Get-ScanDirectory([string] $parent, [string] $name) {
        Assert-StoragePath -Root $root -Path $parent
        $path = Join-Path $parent $name
        if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) { return $null }
        $entry = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (Test-ReparsePoint $entry) {
            $totals.Skipped++
            return $null
        }
        Assert-StoragePath -Root $root -Path $entry.FullName
        if ($entry -isnot [System.IO.DirectoryInfo]) {
            throw "Expected a directory: $path"
        }
        return $entry.FullName
    }

    function Add-Candidate([System.IO.FileInfo] $file, [string] $reason) {
        if (-not $seen.Add($file.FullName)) { return }
        [long] $bytes = $file.Length
        if ($bytes -lt 0 -or $totals.Bytes -gt ([long]::MaxValue - $bytes)) {
            throw "Invalid or overflowing file size: $($file.FullName)"
        }
        $totals.Bytes += $bytes
        $candidates.Add([pscustomobject]@{
            Path = $file.FullName
            Bytes = $bytes
            Reason = $reason
        })
    }

    function Scan-BoundedTree([string] $directory, [string] $kind) {
        $pending = New-Object 'System.Collections.Generic.Stack[object]'
        $pending.Push([pscustomobject]@{ Path = $directory; Segments = @() })
        while ($pending.Count -gt 0) {
            $node = $pending.Pop()
            foreach ($entry in (Get-Children $node.Path)) {
                if (Test-ReparsePoint $entry) {
                    $totals.Skipped++
                    continue
                }
                Assert-LexicalProjectPath $entry.FullName
                if ($entry -is [System.IO.DirectoryInfo]) {
                    if ($script:DiscoveryExclusions -contains $entry.Name) { continue }
                    $segments = @($node.Segments) + @($entry.Name)
                    $pending.Push([pscustomobject]@{ Path = $entry.FullName; Segments = $segments })
                    continue
                }
                if ($entry -isnot [System.IO.FileInfo]) { continue }
                if ($script:GeneratedExtensions -notcontains $entry.Extension) { continue }
                if ($kind -eq 'Intermediate') {
                    $match = $null
                    foreach ($segment in $node.Segments) {
                        if ($wanted.Contains([string] $segment)) { $match = [string] $segment; break }
                    }
                    if ($null -ne $match) { Add-Candidate $entry "Intermediate/Build configuration $match" }
                }
                else {
                    $stem = [System.IO.Path]::GetFileNameWithoutExtension($entry.Name)
                    if ($stem -match '-[A-Za-z0-9_]+-(DebugGame|Debug|Test|Shipping)$' -and $wanted.Contains($Matches[1])) {
                        Add-Candidate $entry "Binaries configuration $($Matches[1])"
                    }
                }
            }
        }
    }

    function Scan-ProjectOrPlugin([string] $base) {
        $intermediate = Get-ScanDirectory $base 'Intermediate'
        if ($null -ne $intermediate) {
            $build = Get-ScanDirectory $intermediate 'Build'
            if ($null -ne $build) { Scan-BoundedTree $build 'Intermediate' }
        }
        $binaries = Get-ScanDirectory $base 'Binaries'
        if ($null -ne $binaries) { Scan-BoundedTree $binaries 'Binaries' }
    }

    Scan-ProjectOrPlugin $root

    $pluginsRoot = Get-ScanDirectory $root 'Plugins'
    if ($null -ne $pluginsRoot) {
        $pendingPlugins = New-Object 'System.Collections.Generic.Stack[string]'
        $pendingPlugins.Push($pluginsRoot)
        while ($pendingPlugins.Count -gt 0) {
            $directory = $pendingPlugins.Pop()
            $children = Get-Children $directory
            $isPlugin = $false
            foreach ($entry in $children) {
                if (Test-ReparsePoint $entry) {
                    $totals.Skipped++
                    continue
                }
                Assert-LexicalProjectPath $entry.FullName
                if ($entry -is [System.IO.FileInfo] -and $entry.Extension -ieq '.uplugin') {
                    $isPlugin = $true
                }
            }
            if ($isPlugin) { Scan-ProjectOrPlugin $directory }
            foreach ($entry in $children) {
                if ($entry -isnot [System.IO.DirectoryInfo] -or (Test-ReparsePoint $entry)) { continue }
                if ($script:DiscoveryExclusions -contains $entry.Name) { continue }
                $pendingPlugins.Push($entry.FullName)
            }
        }
    }

    [pscustomobject]@{
        ProjectFile = $projectFile
        Configurations = @($wanted | Sort-Object)
        CandidateCount = $candidates.Count
        LogicalBytes = $totals.Bytes
        SkippedReparsePoints = $totals.Skipped
        Candidates = @($candidates | Sort-Object Path)
    }
}

Export-ModuleMember -Function Get-ProjectCleanupPreview
