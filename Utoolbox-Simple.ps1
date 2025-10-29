# ============================================================================
# utoolbox-simple.ps1 - Simplified Unreal Engine Project Management Tool
# ============================================================================

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path

# Import modules
Import-Module (Join-Path $scriptPath "UnrealToolboxSimple\UI.psm1") -Force -Global
Import-Module (Join-Path $scriptPath "UnrealToolboxSimple\Settings.psm1") -Force -Global
Import-Module (Join-Path $scriptPath "UnrealToolboxSimple\CommandHistory.psm1") -Force -Global
Import-Module (Join-Path $scriptPath "UnrealToolboxSimple\ProjectManagement.psm1") -Force -Global

# Import Common module using relative path
$commonPath = Join-Path $scriptPath "Common\UnrealEngine.psm1"
if (Test-Path $commonPath) {
    Import-Module $commonPath -Force -Global
} else {
    Write-Host "Error: Cannot find UnrealEngine.psm1 at $commonPath" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

$script:CurrentProject = $null
$script:CurrentEngine = $null
$script:AvailableEngines = @()
$script:ProjectSettings = $null
$script:AnimationFrame = 0
$script:MenuInitialized = $false

# Build configuration state
$script:BuildTarget = "Editor"
$script:BuildConfig = "Development"
$script:BuildPlatform = "Win64"

function Initialize-Toolbox {
    Clear-Host
    Write-Host "Discovering engines..." -ForegroundColor Cyan
    $script:AvailableEngines = Get-AllEngineInstallations -Detailed

    if ($script:AvailableEngines.Count -eq 0) {
        Write-Host "No engines found!" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit
    }

    # Search for project file one level up from script location
    $parentDir = Split-Path $scriptPath -Parent
    $projects = Get-ChildItem -Path $parentDir -Filter "*.uproject" -File -ErrorAction SilentlyContinue
    
    if ($projects.Count -eq 1) {
        $script:CurrentProject = $projects[0].FullName
        $script:ProjectSettings = Load-ProjectSettings $script:CurrentProject

        # Load saved build configuration
        if ($script:ProjectSettings) {
            $script:BuildTarget = $script:ProjectSettings.build.target
            $script:BuildConfig = $script:ProjectSettings.build.config
            $script:BuildPlatform = $script:ProjectSettings.build.platform
        }

        $engineAssoc = Get-ProjectEngineAssociation $script:CurrentProject
        if ($engineAssoc) {
            $matched = $script:AvailableEngines | Where-Object {
                $_.Identifier -eq $engineAssoc -or $_.Version -eq $engineAssoc
            } | Select-Object -First 1
            if ($matched) { $script:CurrentEngine = $matched }
        }
        if (-not $script:CurrentEngine) {
            $script:CurrentEngine = $script:AvailableEngines |
                Where-Object { $_.Source -eq "Launcher" } |
                Sort-Object Version -Descending |
                Select-Object -First 1
        }
    } elseif ($projects.Count -eq 0) {
        Write-Host "No .uproject file found in parent directory: $parentDir" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit
    } else {
        Write-Host "Multiple .uproject files found. Please ensure only one project exists in: $parentDir" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit
    }
}

function Show-MainMenu {
    param([switch]$ForceClear)
    
    if (-not $script:MenuInitialized -or $ForceClear) {
        Clear-Host
        $script:MenuInitialized = $true
    } else {
        [Console]::SetCursorPosition(0, 0)
    }
    
    # Header
    Write-Host "╔═══════════════════════════════════════════════════════════════════════════╗" -ForegroundColor DarkGray
    if ($script:CurrentProject -and $script:CurrentEngine) {
        $projectName = Split-Path $script:CurrentProject -Leaf
        Write-Host "║ " -NoNewline -ForegroundColor DarkGray
        Write-Host "$projectName" -NoNewline -ForegroundColor White
        Write-Host " │ " -NoNewline -ForegroundColor DarkGray
        Write-Host "UE $($script:CurrentEngine.Version)" -NoNewline -ForegroundColor Cyan
        Write-Host " (" -NoNewline -ForegroundColor DarkGray
        Write-Host $script:CurrentEngine.Source -NoNewline -ForegroundColor $(if ($script:CurrentEngine.Source -eq "Launcher") { "Green" } else { "Magenta" })
        Write-Host ")" -NoNewline -ForegroundColor DarkGray
        
        $infoLength = $projectName.Length + $script:CurrentEngine.Version.Length + $script:CurrentEngine.Source.Length + 11
        $padding = 75 - $infoLength
        if ($padding -gt 0) {
            Write-Host (" " * $padding) -NoNewline
        }
        Write-Host "║" -ForegroundColor DarkGray
    }
    Write-Host "╚═══════════════════════════════════════════════════════════════════════════╝" -ForegroundColor DarkGray
    Write-Host ""

    # Check if editor is running
    $isRunning = Test-ProjectRunning -ProjectPath $script:CurrentProject

    if ($script:CurrentProject) {
        Write-Host "📁 Project" -NoNewline -ForegroundColor Yellow
        if ($isRunning) {
            $frames = @(
                @{ Symbol = "🔴"; Pattern = "[●●●○]"; Text = "EDITOR RUNNING" },
                @{ Symbol = "🟠"; Pattern = "[●●○●]"; Text = "EDITOR RUNNING" },
                @{ Symbol = "🟡"; Pattern = "[●○●●]"; Text = "EDITOR RUNNING" },
                @{ Symbol = "🟢"; Pattern = "[○●●●]"; Text = "EDITOR RUNNING" }
            )
            $frame = $frames[$script:AnimationFrame % $frames.Count]
            $script:AnimationFrame++
            
            Write-Host " $($frame.Symbol) $($frame.Pattern) " -NoNewline -ForegroundColor Red
            Write-Host $frame.Text -ForegroundColor Red
        } else {
            Write-Host (" " * 70)
        }
        Write-Host "   " -NoNewline
        Write-Host (Split-Path $script:CurrentProject -Leaf) -ForegroundColor White
        Write-Host "   " -NoNewline
        Write-Host $script:CurrentProject -NoNewline -ForegroundColor DarkGray
        Write-Host (" " * 20)
    }

    if ($script:CurrentEngine) {
        Write-Host "⚙️  Engine" -ForegroundColor Yellow
        Write-Host "   " -NoNewline
        Write-Host $script:CurrentEngine.Path -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host ""

    # Check if submodules exist
    $projectDir = Split-Path $script:CurrentProject
    $hasSubmodules = Test-Path (Join-Path $projectDir ".gitmodules")
    
    # Get execution times
    $recentGenerate = Get-RecentGenerateCommands -Count 1 -Settings $script:ProjectSettings
    $recentBuild = Get-RecentBuildCommands -Count 1 -Settings $script:ProjectSettings
    $recentCombined = Get-RecentCombinedCommands -Count 1 -Settings $script:ProjectSettings
    
    $generateTime = ""
    if ($recentGenerate.Count -gt 0 -and $null -ne $recentGenerate[0].ExecutionTimeSeconds -and $recentGenerate[0].ExecutionTimeSeconds -gt 0) {
        $generateTime = " (" + (Format-ExecutionTime $recentGenerate[0].ExecutionTimeSeconds) + ")"
    }
    
    $buildTime = ""
    if ($recentBuild.Count -gt 0 -and $null -ne $recentBuild[0].ExecutionTimeSeconds -and $recentBuild[0].ExecutionTimeSeconds -gt 0) {
        $buildTime = " (" + (Format-ExecutionTime $recentBuild[0].ExecutionTimeSeconds) + ")"
    }
    
    $combinedTime = ""
    if ($recentCombined.Count -gt 0 -and $null -ne $recentCombined[0].ExecutionTimeSeconds -and $recentCombined[0].ExecutionTimeSeconds -gt 0) {
        $combinedTime = " (" + (Format-ExecutionTime $recentCombined[0].ExecutionTimeSeconds) + ")"
    }
    
    Write-Host "► Quick Actions" -ForegroundColor Green
    
    # Option 1: Generate
    $color1 = if ($isRunning) { "DarkGray" } else { "Cyan" }
    Write-Host "  [1] ⚙️  Generate Project Files" -NoNewline -ForegroundColor $color1
    if ($generateTime) {
        Write-Host $generateTime -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
    
    # Option 2: Build with configuration
    $color2 = if ($isRunning) { "DarkGray" } else { "Cyan" }
    Write-Host "  [2] 🔨 Build Project" -NoNewline -ForegroundColor $color2
    if ($buildTime) {
        Write-Host $buildTime -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }
    
    # Build configuration toggles
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentProject)
    $targetName = switch ($script:BuildTarget) {
        "Editor" { "$($projectName)Editor" }
        "Server" { "$($projectName)Server" }
        "Client" { "$($projectName)Client" }
        default { $projectName }
    }
    
    $targetEmoji = switch ($script:BuildTarget) {
        "Editor" { "✏️" }
        "Server" { "🖥️" }
        "Client" { "👤" }
        default { "🎮" }
    }
    
    $configEmoji = switch ($script:BuildConfig) {
        "Development" { "🔧" }
        "DebugGame" { "🐛" }
        "Shipping" { "📦" }
        "Test" { "🧪" }
        default { "🔧" }
    }
    
    $platformEmoji = switch ($script:BuildPlatform) {
        "Win64" { "🪟" }
        "Linux" { "🐧" }
        "Android" { "🤖" }
        default { "🪟" }
    }
    
    $toggleColor = if ($isRunning) { "DarkGray" } else { "Yellow" }
    Write-Host "      Target: " -NoNewline -ForegroundColor Gray
    Write-Host "[T] $targetEmoji $($script:BuildTarget)" -NoNewline -ForegroundColor $toggleColor
    Write-Host " │ " -NoNewline -ForegroundColor DarkGray
    Write-Host "Config: " -NoNewline -ForegroundColor Gray
    Write-Host "[C] $configEmoji $($script:BuildConfig)" -NoNewline -ForegroundColor $toggleColor
    Write-Host " │ " -NoNewline -ForegroundColor DarkGray
    Write-Host "Platform: " -NoNewline -ForegroundColor Gray
    Write-Host "[P] $platformEmoji $($script:BuildPlatform)" -ForegroundColor $toggleColor
    Write-Host ""
    
    # Option 3: Update Submodules
    $color3 = if ($isRunning -or -not $hasSubmodules) { "DarkGray" } else { "Cyan" }
    $suffix3 = if (-not $hasSubmodules) { " (no .gitmodules)" } else { "" }
    Write-Host "  [3] 📦 Update Git Submodules$suffix3" -ForegroundColor $color3
    
    # Option 4: Switch Engine
    $color4 = if ($isRunning) { "DarkGray" } else { "Cyan" }
    Write-Host "  [4] 🔄 Switch Engine" -ForegroundColor $color4
    
    # Option 5: Clean
    $color5 = if ($isRunning) { "DarkGray" } else { "Cyan" }
    Write-Host "  [5] 🧹 Clean Intermediate/Binaries" -ForegroundColor $color5
    
    # Option 6: Combined
    $color6 = if ($isRunning -or -not $hasSubmodules) { "DarkGray" } else { "Cyan" }
    $suffix6 = if (-not $hasSubmodules) { " (no .gitmodules)" } else { "" }
    Write-Host "  [6] 🚀 Update Submodules → Generate → Build" -NoNewline -ForegroundColor $color6
    if ($combinedTime) {
        Write-Host $combinedTime -NoNewline -ForegroundColor DarkGray
    }
    Write-Host $suffix6 -ForegroundColor $color6
    
    Write-Host ""
    Write-Host "  [Q] Quit │ [ESC] Exit" -ForegroundColor Gray
    Write-Host ""

    $key = if ($isRunning) {
        Read-SingleKey -TimeoutMilliseconds 500
    } else {
        Read-SingleKey -TimeoutMilliseconds 5000
    }
    
    if ($null -eq $key) {
        return
    }

    # Save settings helper
    $saveSettings = {
        if ($script:ProjectSettings) {
            $script:ProjectSettings.build.target = $script:BuildTarget
            $script:ProjectSettings.build.config = $script:BuildConfig
            $script:ProjectSettings.build.platform = $script:BuildPlatform
            Save-ProjectSettings -ProjectPath $script:CurrentProject -Settings $script:ProjectSettings
        }
    }

    switch ($key) {
        "1" {
            if ($isRunning) {
                Write-Host "`nCannot generate while editor is running!" -ForegroundColor Red
                Start-Sleep -Seconds 2
            } else {
                if (Show-Confirmation "Generate project files?") {
                    Invoke-GenerateProjectFiles -Engine $script:CurrentEngine -ProjectPath $script:CurrentProject -Settings $script:ProjectSettings
                    Read-Host "`nPress Enter to continue"
                }
                Show-MainMenu -ForceClear
                return
            }
        }
        "2" {
            if ($isRunning) {
                Write-Host "`nCannot build while editor is running!" -ForegroundColor Red
                Start-Sleep -Seconds 2
            } else {
                if (Show-Confirmation "Build project ($targetName $($script:BuildConfig) $($script:BuildPlatform))?") {
                    & $saveSettings
                    Invoke-BuildProject -Target $targetName -Config $script:BuildConfig -Platform $script:BuildPlatform `
                        -ProjectPath $script:CurrentProject -Engine $script:CurrentEngine -Settings $script:ProjectSettings
                    Read-Host "`nPress Enter to continue"
                }
                Show-MainMenu -ForceClear
                return
            }
        }
        "3" {
            if ($isRunning) {
                Write-Host "`nCannot update submodules while editor is running!" -ForegroundColor Red
                Start-Sleep -Seconds 2
            } elseif (-not $hasSubmodules) {
                Write-Host "`nNo .gitmodules file found!" -ForegroundColor Red
                Start-Sleep -Seconds 2
            } else {
                if (Show-Confirmation "Update git submodules?") {
                    Invoke-UpdateSubmodules -CurrentProject $script:CurrentProject
                    Read-Host "`nPress Enter to continue"
                }
                Show-MainMenu -ForceClear
                return
            }
        }
        "4" {
            if ($isRunning) {
                Write-Host "`nCannot switch engine while editor is running!" -ForegroundColor Red
                Start-Sleep -Seconds 2
            } else {
                Show-SwitchEngineMenu -CurrentEngine ([ref]$script:CurrentEngine) `
                    -AvailableEngines $script:AvailableEngines -CurrentProject $script:CurrentProject
                Show-MainMenu -ForceClear
                return
            }
        }
        "5" {
            if ($isRunning) {
                Write-Host "`nCannot clean while editor is running!" -ForegroundColor Red
                Start-Sleep -Seconds 2
            } else {
                if (Show-Confirmation "Clean intermediate and binaries?" -Dangerous) {
                    Invoke-CleanProject -CurrentProject $script:CurrentProject
                    Read-Host "Press Enter to continue"
                }
                Show-MainMenu -ForceClear
                return
            }
        }
        "6" {
            if ($isRunning) {
                Write-Host "`nCannot run combined operation while editor is running!" -ForegroundColor Red
                Start-Sleep -Seconds 2
            } elseif (-not $hasSubmodules) {
                Write-Host "`nNo .gitmodules file found!" -ForegroundColor Red
                Start-Sleep -Seconds 2
            } else {
                if (Show-Confirmation "Run combined operation (Update → Generate → Build)?") {
                    & $saveSettings
                    Invoke-CombinedOperation -Target $targetName -Config $script:BuildConfig -Platform $script:BuildPlatform `
                        -ProjectPath $script:CurrentProject -Engine $script:CurrentEngine -Settings $script:ProjectSettings
                }
                Show-MainMenu -ForceClear
                return
            }
        }
        "T" {
            if (-not $isRunning) {
                $targets = @("Editor", "Game", "Server", "Client")
                $currentIndex = $targets.IndexOf($script:BuildTarget)
                $script:BuildTarget = $targets[($currentIndex + 1) % $targets.Count]
                & $saveSettings
            }
        }
        "C" {
            if (-not $isRunning) {
                $configs = @("Development", "DebugGame", "Shipping", "Test")
                $currentIndex = $configs.IndexOf($script:BuildConfig)
                $script:BuildConfig = $configs[($currentIndex + 1) % $configs.Count]
                & $saveSettings
            }
        }
        "P" {
            if (-not $isRunning) {
                $platforms = @("Win64", "Linux", "Android")
                $currentIndex = $platforms.IndexOf($script:BuildPlatform)
                $script:BuildPlatform = $platforms[($currentIndex + 1) % $platforms.Count]
                & $saveSettings
            }
        }
        { $_ -in @("Q", 27) } { exit }
    }
}

Initialize-Toolbox
while ($true) { Show-MainMenu }
