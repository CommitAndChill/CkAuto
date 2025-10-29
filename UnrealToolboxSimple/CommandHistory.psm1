# ============================================================================
# CommandHistory.psm1 - Command history tracking
# ============================================================================

function Add-GenerateCommandToHistory {
    param(
        [string]$ProjectPath,
        [object]$Engine,
        [hashtable]$Settings,
        [double]$ExecutionTimeSeconds = 0
    )
    
    if (-not $Settings) { return }
    
    $entry = [PSCustomObject]@{
        Type = "Generate"
        Timestamp = (Get-Date).ToString("o")
        ProjectPath = $ProjectPath
        ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
        EngineVersion = $Engine.Version
        EngineSource = $Engine.Source
        EnginePath = $Engine.Path
        EngineIdentifier = $Engine.Identifier
        ExecutionTimeSeconds = $ExecutionTimeSeconds
    }
    
    $Settings.history.generate = @($entry) + @($Settings.history.generate | Select-Object -First 4)
    Save-ProjectSettings -ProjectPath $ProjectPath -Settings $Settings
}

function Add-BuildCommandToHistory {
    param(
        [string]$Target,
        [string]$Config,
        [string]$Platform,
        [string]$ProjectPath,
        [object]$Engine,
        [hashtable]$Settings,
        [double]$ExecutionTimeSeconds = 0
    )
    
    if (-not $Settings) { return }
    
    $entry = [PSCustomObject]@{
        Type = "Build"
        Timestamp = (Get-Date).ToString("o")
        Target = $Target
        Config = $Config
        Platform = $Platform
        ProjectPath = $ProjectPath
        ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
        EngineVersion = $Engine.Version
        EngineSource = $Engine.Source
        EnginePath = $Engine.Path
        EngineIdentifier = $Engine.Identifier
        ExecutionTimeSeconds = $ExecutionTimeSeconds
    }
    
    $Settings.history.build = @($entry) + @($Settings.history.build | Select-Object -First 4)
    Save-ProjectSettings -ProjectPath $ProjectPath -Settings $Settings
}

function Add-CombinedCommandToHistory {
    param(
        [string]$Target,
        [string]$Config,
        [string]$Platform,
        [string]$ProjectPath,
        [object]$Engine,
        [hashtable]$Settings,
        [double]$SubmodulesTime = 0,
        [double]$GenerateTime = 0,
        [double]$BuildTime = 0,
        [double]$TotalTime = 0
    )
    
    if (-not $Settings) { return }
    
    $entry = [PSCustomObject]@{
        Type = "Combined"
        Timestamp = (Get-Date).ToString("o")
        Target = $Target
        Config = $Config
        Platform = $Platform
        ProjectPath = $ProjectPath
        ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
        EngineVersion = $Engine.Version
        EngineSource = $Engine.Source
        EnginePath = $Engine.Path
        EngineIdentifier = $Engine.Identifier
        SubmodulesTimeSeconds = $SubmodulesTime
        GenerateTimeSeconds = $GenerateTime
        BuildTimeSeconds = $BuildTime
        ExecutionTimeSeconds = $TotalTime
    }
    
    $Settings.history.combined = @($entry) + @($Settings.history.combined | Select-Object -First 4)
    Save-ProjectSettings -ProjectPath $ProjectPath -Settings $Settings
}

function Get-RecentGenerateCommands {
    param(
        [int]$Count = 1,
        [hashtable]$Settings
    )
    
    if (-not $Settings -or -not $Settings.history) { return @() }
    return $Settings.history.generate | Select-Object -First $Count
}

function Get-RecentBuildCommands {
    param(
        [int]$Count = 1,
        [hashtable]$Settings
    )
    
    if (-not $Settings -or -not $Settings.history) { return @() }
    return $Settings.history.build | Select-Object -First $Count
}

function Get-RecentCombinedCommands {
    param(
        [int]$Count = 1,
        [hashtable]$Settings
    )
    
    if (-not $Settings -or -not $Settings.history) { return @() }
    return $Settings.history.combined | Select-Object -First $Count
}

function Format-ExecutionTime {
    param([double]$Seconds)
    
    if ($Seconds -eq 0) { return "" }
    
    if ($Seconds -lt 60) {
        return "$([Math]::Round($Seconds))s"
    }
    elseif ($Seconds -lt 3600) {
        $mins = [Math]::Floor($Seconds / 60)
        $secs = [Math]::Round($Seconds % 60)
        if ($secs -eq 0) {
            return "$($mins)m"
        } else {
            return "$($mins)m $($secs)s"
        }
    }
    else {
        $hours = [Math]::Floor($Seconds / 3600)
        $mins = [Math]::Floor(($Seconds % 3600) / 60)
        if ($mins -eq 0) {
            return "$($hours)h"
        } else {
            return "$($hours)h $($mins)m"
        }
    }
}

Export-ModuleMember -Function @(
    'Add-GenerateCommandToHistory',
    'Add-BuildCommandToHistory',
    'Add-CombinedCommandToHistory',
    'Get-RecentGenerateCommands',
    'Get-RecentBuildCommands',
    'Get-RecentCombinedCommands',
    'Format-ExecutionTime'
)
