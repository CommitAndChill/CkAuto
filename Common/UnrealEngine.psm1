# ============================================================================
# UnrealEngine.psm1 - Core Unreal Engine utilities library
# ============================================================================

function Test-ValidEngineDirectory {
    <#
    .SYNOPSIS
    Validates if a directory is a valid Unreal Engine installation.
    #>
    param([string]$RootDir)
    
    if (-not (Test-Path $RootDir)) { return $false }
    
    $binariesPath = Join-Path $RootDir "Engine\Binaries"
    $buildPath = Join-Path $RootDir "Engine\Build"
    
    return (Test-Path $binariesPath) -and (Test-Path $buildPath)
}

function Get-LauncherEngineInstallations {
    <#
    .SYNOPSIS
    Gets Unreal Engine installations from Epic Games Launcher.
    #>
    
    # Try ProgramData first (current location), then AppData (legacy)
    $launcherDataFile = Join-Path $env:ProgramData "Epic\UnrealEngineLauncher\LauncherInstalled.dat"
    
    if (-not (Test-Path $launcherDataFile)) {
        $launcherDataFile = Join-Path $env:APPDATA "UnrealEngineLauncher\LauncherInstalled.dat"
    }
    
    if (-not (Test-Path $launcherDataFile)) {
        Write-Verbose "Launcher data file not found"
        return @{}
    }
    
    try {
        $jsonContent = Get-Content $launcherDataFile -Raw | ConvertFrom-Json
        $installations = @{}
        
        foreach ($install in $jsonContent.InstallationList) {
            $appName = $install.AppName
            $installLocation = $install.InstallLocation
            
            if ($appName -and $installLocation -and $appName.StartsWith("UE_")) {
                $version = $appName.Substring(3)
                
                if (Test-ValidEngineDirectory $installLocation) {
                    $installations[$version] = $installLocation
                    Write-Verbose "Found launcher installation: $version at $installLocation"
                }
            }
        }
        
        return $installations
    }
    catch {
        Write-Warning "Failed to parse launcher data: $_"
        return @{}
    }
}

function Get-CustomEngineInstallations {
    <#
    .SYNOPSIS
    Gets custom Unreal Engine installations from Windows registry.
    #>
    
    $registryPath = "HKCU:\SOFTWARE\Epic Games\Unreal Engine\Builds"
    
    if (-not (Test-Path $registryPath)) {
        Write-Verbose "Registry path not found: $registryPath"
        return @{}
    }
    
    try {
        $installations = @{}
        $regKey = Get-Item $registryPath
        
        foreach ($valueName in $regKey.GetValueNames()) {
            $installPath = $regKey.GetValue($valueName)
            
            if ($installPath -and (Test-ValidEngineDirectory $installPath)) {
                $installations[$valueName] = $installPath
                Write-Verbose "Found custom installation: $valueName at $installPath"
            }
            else {
                Write-Verbose "Invalid or missing installation: $valueName -> $installPath"
            }
        }
        
        return $installations
    }
    catch {
        Write-Warning "Failed to read registry: $_"
        return @{}
    }
}

function Get-EngineVersion {
    <#
    .SYNOPSIS
    Gets the version number from an engine installation.
    #>
    param([string]$RootDir)
    
    $buildVersionPath = Join-Path $RootDir "Engine\Build\Build.version"
    
    if (Test-Path $buildVersionPath) {
        try {
            $versionJson = Get-Content $buildVersionPath -Raw | ConvertFrom-Json
            return "$($versionJson.MajorVersion).$($versionJson.MinorVersion).$($versionJson.PatchVersion)"
        }
        catch {
            Write-Verbose "Failed to parse Build.version: $_"
        }
    }
    
    return $null
}

function Get-EngineType {
    <#
    .SYNOPSIS
    Determines if engine is Source or Binary distribution.
    #>
    param([string]$RootDir)
    
    $sourceDistPath = Join-Path $RootDir "Engine\Build\SourceDistribution.txt"
    
    if (Test-Path $sourceDistPath) {
        return "Source"
    }
    
    return "Binary"
}

function Register-CustomEngine {
    <#
    .SYNOPSIS
    Registers a custom engine installation in the Windows registry.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RootDir
    )
    
    if (-not (Test-ValidEngineDirectory $RootDir)) {
        Write-Error "Invalid engine directory: $RootDir"
        return $null
    }
    
    $registryPath = "HKCU:\SOFTWARE\Epic Games\Unreal Engine\Builds"
    
    if (-not (Test-Path $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }
    
    $guid = [System.Guid]::NewGuid().ToString("B")
    
    try {
        Set-ItemProperty -Path $registryPath -Name $guid -Value $RootDir
        Write-Host "Registered engine with identifier: $guid"
        return $guid
    }
    catch {
        Write-Error "Failed to register engine: $_"
        return $null
    }
}

function Get-AllEngineInstallations {
    <#
    .SYNOPSIS
    Gets all Unreal Engine installations (launcher + custom).
    #>
    param([switch]$Detailed)
    
    Write-Verbose "Discovering Unreal Engine installations..."
    
    $launcherEngines = Get-LauncherEngineInstallations
    $customEngines = Get-CustomEngineInstallations
    
    $allEngines = @()
    
    foreach ($entry in $launcherEngines.GetEnumerator()) {
        $engineInfo = [PSCustomObject]@{
            Identifier = $entry.Key
            Path = $entry.Value
            Source = "Launcher"
            Type = Get-EngineType $entry.Value
            Version = Get-EngineVersion $entry.Value
        }
        $allEngines += $engineInfo
    }
    
    foreach ($entry in $customEngines.GetEnumerator()) {
        $version = Get-EngineVersion $entry.Value
        
        $engineInfo = [PSCustomObject]@{
            Identifier = $entry.Key
            Path = $entry.Value
            Source = "Custom"
            Type = Get-EngineType $entry.Value
            Version = if ($version) { $version } else { "Unknown" }
        }
        $allEngines += $engineInfo
    }
    
    if ($Detailed) {
        return $allEngines
    }
    else {
        return $allEngines | Select-Object Identifier, Version, Source, Path
    }
}

function Find-UProjectFiles {
    <#
    .SYNOPSIS
    Finds .uproject files in the current directory and subdirectories.
    #>
    param(
        [string]$StartPath = (Get-Location).Path,
        [int]$MaxDepth = 2
    )
    
    $projects = Get-ChildItem -Path $StartPath -Filter "*.uproject" -Recurse -Depth $MaxDepth -ErrorAction SilentlyContinue
    return $projects
}

function Get-ProjectEngineAssociation {
    <#
    .SYNOPSIS
    Gets the engine association from a .uproject file.
    #>
    param([string]$ProjectPath)
    
    if (-not (Test-Path $ProjectPath)) {
        return $null
    }
    
    try {
        $projectJson = Get-Content $ProjectPath -Raw | ConvertFrom-Json
        return $projectJson.EngineAssociation
    }
    catch {
        Write-Warning "Failed to parse project file: $_"
        return $null
    }
}

function Set-ProjectEngineAssociation {
    <#
    .SYNOPSIS
    Sets the engine association in a .uproject file.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath,
        [Parameter(Mandatory)]
        [string]$EngineAssociation
    )
    
    if (-not (Test-Path $ProjectPath)) {
        Write-Error "Project file not found: $ProjectPath"
        return $false
    }
    
    try {
        $projectJson = Get-Content $ProjectPath -Raw | ConvertFrom-Json
        $projectJson.EngineAssociation = $EngineAssociation
        
        $projectJson | ConvertTo-Json -Depth 100 | Set-Content $ProjectPath -Encoding UTF8
        Write-Verbose "Updated engine association to: $EngineAssociation"
        return $true
    }
    catch {
        Write-Error "Failed to update project file: $_"
        return $false
    }
}

function Get-UnrealBuildToolPath {
    <#
    .SYNOPSIS
    Gets the path to UnrealBuildTool.exe for a given engine.
    #>
    param([string]$EnginePath)
    
    $ubtPath = Join-Path $EnginePath "Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe"
    
    if (Test-Path $ubtPath) {
        return $ubtPath
    }
    
    return $null
}

function Get-RunUATPath {
    <#
    .SYNOPSIS
    Gets the path to RunUAT.bat for a given engine.
    #>
    param([string]$EnginePath)
    
    $uatPath = Join-Path $EnginePath "Engine\Build\BatchFiles\RunUAT.bat"
    
    if (Test-Path $uatPath) {
        return $uatPath
    }
    
    return $null
}

function Invoke-UnrealBuildTool {
    <#
    .SYNOPSIS
    Invokes UnrealBuildTool with the specified arguments.
    #>
    param(
        [string]$EnginePath,
        [string]$Arguments,
        [switch]$ShowOutput
    )
    
    $ubtPath = Get-UnrealBuildToolPath $EnginePath
    
    if (-not $ubtPath) {
        Write-Error "UnrealBuildTool not found in engine: $EnginePath"
        return $false
    }
    
    Write-Host "Running: $ubtPath $Arguments" -ForegroundColor Cyan
    
    if ($ShowOutput) {
        $process = Start-Process -FilePath $ubtPath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
    }
    else {
        $process = Start-Process -FilePath $ubtPath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput "NUL"
    }
    
    return $process.ExitCode -eq 0
}

function Invoke-RunUAT {
    <#
    .SYNOPSIS
    Invokes RunUAT with the specified arguments.
    #>
    param(
        [string]$EnginePath,
        [string]$Arguments,
        [switch]$ShowOutput
    )
    
    $uatPath = Get-RunUATPath $EnginePath
    
    if (-not $uatPath) {
        Write-Error "RunUAT not found in engine: $EnginePath"
        return $false
    }
    
    Write-Host "Running: $uatPath $Arguments" -ForegroundColor Cyan
    
    if ($ShowOutput) {
        $process = Start-Process -FilePath $uatPath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
    }
    else {
        $process = Start-Process -FilePath $uatPath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput "NUL"
    }
    
    return $process.ExitCode -eq 0
}

function Test-ProjectRunning {
    <#
    .SYNOPSIS
    Checks if a project is currently running in the Unreal Editor.
    #>
    param([string]$ProjectPath)
    
    if (-not $ProjectPath -or -not (Test-Path $ProjectPath)) {
        return $false
    }
    
    # Get project name for matching
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    
    # Check for editor processes - UE5 uses UnrealEditor-Win64-[Config] pattern
    # Get all processes that start with UnrealEditor or UE4Editor
    $allProcesses = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -like "UnrealEditor*" -or $_.ProcessName -like "UE4Editor*"
    }
    
    foreach ($proc in $allProcesses) {
        # Check MainWindowTitle which contains the project name
        # Format: "ProjectName [Config] - Unreal Editor"
        if ($proc.MainWindowTitle -and $proc.MainWindowTitle -like "*$projectName*") {
            return $true
        }
        
        # Also try CommandLine as backup (may require elevated permissions)
        try {
            $cmdLine = $proc.CommandLine
            if ($cmdLine) {
                $normalizedProjectPath = [System.IO.Path]::GetFullPath($ProjectPath)
                if ($cmdLine -like "*$normalizedProjectPath*" -or $cmdLine -like "*$projectName.uproject*") {
                    return $true
                }
            }
        }
        catch {
            # CommandLine access denied - that's okay, window title is more reliable anyway
        }
    }
    
    return $false
}

function Stop-ProjectEditor {
    <#
    .SYNOPSIS
    Terminates running Unreal Editor processes for a specific project.
    #>
    param([string]$ProjectPath)
    
    if (-not $ProjectPath) {
        Write-Warning "No project path provided"
        return $false
    }
    
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    
    # Get all processes without filtering first
    $allProcesses = @()
    try {
        $allProcesses = Get-Process | Where-Object {
            $_.ProcessName -match "^(UnrealEditor|UE4Editor)"
        }
    }
    catch {
        Write-Warning "Failed to get processes: $_"
        return $false
    }
    
    Write-Host "Looking for project: $projectName" -ForegroundColor Gray
    Write-Host "Found $($allProcesses.Count) editor process(es)" -ForegroundColor Gray
    
    $killed = $false
    
    foreach ($proc in $allProcesses) {
        Write-Host "  Process: $($proc.ProcessName) (PID: $($proc.Id))" -ForegroundColor Gray
        Write-Host "  Window Title: '$($proc.MainWindowTitle)'" -ForegroundColor Gray
        
        # Check MainWindowTitle for project name (case-insensitive)
        $title = $proc.MainWindowTitle
        if ($title -and $title.IndexOf($projectName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            try {
                Write-Host "  -> MATCH! Terminating..." -ForegroundColor Yellow
                Stop-Process -Id $proc.Id -Force
                Start-Sleep -Milliseconds 500
                $killed = $true
            }
            catch {
                Write-Warning "Failed to terminate process $($proc.Id): $_"
            }
        } else {
            Write-Host "  -> No match" -ForegroundColor DarkGray
        }
    }
    
    if (-not $killed) {
        Write-Host ""
        Write-Host "Debug: Trying alternate detection..." -ForegroundColor Yellow
        # Fallback: kill any UnrealEditor process as last resort
        foreach ($proc in $allProcesses) {
            try {
                Write-Host "  Terminating $($proc.ProcessName) (PID: $($proc.Id))" -ForegroundColor Yellow
                Stop-Process -Id $proc.Id -Force
                Start-Sleep -Milliseconds 500
                $killed = $true
            }
            catch {
                Write-Warning "Failed: $_"
            }
        }
    }
    
    return $killed
}

# Export functions
Export-ModuleMember -Function @(
    'Test-ValidEngineDirectory',
    'Get-AllEngineInstallations',
    'Get-LauncherEngineInstallations',
    'Get-CustomEngineInstallations',
    'Get-EngineVersion',
    'Get-EngineType',
    'Register-CustomEngine',
    'Find-UProjectFiles',
    'Get-ProjectEngineAssociation',
    'Set-ProjectEngineAssociation',
    'Get-UnrealBuildToolPath',
    'Get-RunUATPath',
    'Invoke-UnrealBuildTool',
    'Invoke-RunUAT',
    'Test-ProjectRunning',
    'Stop-ProjectEditor'
)
