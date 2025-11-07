# ============================================================================
# ProjectManagement.psm1 - Project operations
# ============================================================================

function Invoke-GenerateProjectFiles {
    param($Engine, $ProjectPath, $Settings)

    Write-Host ""
    Write-Host "Generating project files..." -ForegroundColor Yellow

    $ubtPath = Get-UnrealBuildToolPath $Engine.Path
    if (-not $ubtPath) {
        Write-Host "UnrealBuildTool not found!" -ForegroundColor Red
        return $false
    }

    $args = '-projectfiles -project="{0}" -game -engine' -f $ProjectPath

    Write-Host ""
    Write-Host "Command: " -NoNewline -ForegroundColor Gray
    Write-Host ('"' + $ubtPath + '" ' + $args) -ForegroundColor Cyan
    Write-Host ""

    $startTime = Get-Date
    $success = Invoke-UnrealBuildTool -EnginePath $Engine.Path -Arguments $args -ShowOutput
    $endTime = Get-Date
    $executionTime = ($endTime - $startTime).TotalSeconds

    if ($success) {
        Write-Host "Success! " -NoNewline -ForegroundColor Green
        Write-Host "(" -NoNewline -ForegroundColor DarkGray
        Write-Host (Format-ExecutionTime $executionTime) -NoNewline -ForegroundColor Cyan
        Write-Host ")" -ForegroundColor DarkGray
        Add-GenerateCommandToHistory -ProjectPath $ProjectPath -Engine $Engine -Settings $Settings -ExecutionTimeSeconds $executionTime
    } else {
        Write-Host "Failed." -ForegroundColor Red
    }

    return $success
}

function Invoke-BuildProject {
    param([string]$Target, [string]$Config, [string]$Platform, [string]$ProjectPath, [object]$Engine, [hashtable]$Settings)

    Write-Host ""
    Write-Host "Building: $Target $Config $Platform" -ForegroundColor Yellow

    $ubtPath = Get-UnrealBuildToolPath $Engine.Path
    $args = '{0} {1} {2} -project="{3}"' -f $Target, $Config, $Platform, $ProjectPath

    Write-Host ""
    Write-Host "Command: " -NoNewline -ForegroundColor Gray
    Write-Host ('"' + $ubtPath + '" ' + $args) -ForegroundColor Cyan
    Write-Host ""

    $startTime = Get-Date
    $success = Invoke-UnrealBuildTool -EnginePath $Engine.Path -Arguments $args -ShowOutput
    $endTime = Get-Date
    $executionTime = ($endTime - $startTime).TotalSeconds

    if ($success) {
        Write-Host "Success! " -NoNewline -ForegroundColor Green
        Write-Host "(" -NoNewline -ForegroundColor DarkGray
        Write-Host (Format-ExecutionTime $executionTime) -NoNewline -ForegroundColor Cyan
        Write-Host ")" -ForegroundColor DarkGray
        Add-BuildCommandToHistory -Target $Target -Config $Config -Platform $Platform `
            -ProjectPath $ProjectPath -Engine $Engine -Settings $Settings -ExecutionTimeSeconds $executionTime
    } else {
        Write-Host "Failed." -ForegroundColor Red
    }

    return $success
}

function Invoke-CleanProject {
    param([string]$CurrentProject)

    if (-not $CurrentProject) {
        Write-Host "No project!" -ForegroundColor Red
        Start-Sleep -Seconds 1
        return
    }

    Write-Host ""
    Write-Host "Cleaning..." -ForegroundColor Yellow

    $dir = Split-Path $CurrentProject
    $cleaned = $false

    if (Test-Path (Join-Path $dir "Intermediate")) {
        Remove-Item (Join-Path $dir "Intermediate") -Recurse -Force
        Write-Host "Removed Intermediate" -ForegroundColor Green
        $cleaned = $true
    }

    if (Test-Path (Join-Path $dir "Binaries")) {
        Remove-Item (Join-Path $dir "Binaries") -Recurse -Force
        Write-Host "Removed Binaries" -ForegroundColor Green
        $cleaned = $true
    }

    if (-not $cleaned) {
        Write-Host "Nothing to clean" -ForegroundColor Yellow
    }

    Write-Host ""
}

function Invoke-UpdateSubmodules {
    param([string]$CurrentProject)

    if (-not $CurrentProject) {
        Write-Host "No project!" -ForegroundColor Red
        return $false
    }

    $projectDir = Split-Path $CurrentProject
    $gitDir = Join-Path $projectDir ".git"

    if (-not (Test-Path $gitDir)) {
        Write-Host "This is not a git repository!" -ForegroundColor Red
        return $false
    }

    $gitmodulesPath = Join-Path $projectDir ".gitmodules"
    if (-not (Test-Path $gitmodulesPath)) {
        Write-Host "No submodules found (.gitmodules doesn't exist)" -ForegroundColor Yellow
        return $false
    }

    Write-Host ""
    Write-Host "Updating submodules..." -ForegroundColor Yellow
    Write-Host ""

    Push-Location $projectDir
    try {
        # Step 1: Sync remote URLs from .gitmodules to .git/config
        Write-Host "Step 1: Syncing submodule remotes..." -ForegroundColor Cyan
        Write-Host "Command: " -NoNewline -ForegroundColor Gray
        Write-Host "git submodule sync --recursive" -ForegroundColor Cyan
        Write-Host ""
        
        & git submodule sync --recursive
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            Write-Host ""
            Write-Host "Failed to sync submodules (exit code: $exitCode)" -ForegroundColor Red
            return $false
        }

        Write-Host ""
        Write-Host "Step 2: Updating submodules..." -ForegroundColor Cyan
        Write-Host "Command: " -NoNewline -ForegroundColor Gray
        Write-Host "git submodule update --init --recursive" -ForegroundColor Cyan
        Write-Host ""

        # Step 2: Update submodules with synced URLs
        & git submodule update --init --recursive
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Host ""
            Write-Host "Success!" -ForegroundColor Green
            return $true
        } else {
            Write-Host ""
            Write-Host "Failed (exit code: $exitCode)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host ""
        Write-Host "Error: $_" -ForegroundColor Red
        return $false
    }
    finally {
        Pop-Location
    }
}

function Invoke-CombinedOperation {
    param([string]$Target, [string]$Config, [string]$Platform, [string]$ProjectPath, [object]$Engine, [hashtable]$Settings)

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "🚀 COMBINED OPERATION: Update Submodules → Generate → Build → Launch" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    $totalStartTime = Get-Date
    $submodulesTime = 0
    $generateTime = 0
    $buildTime = 0
    $launchTime = 0

    # Step 1: Update Submodules
    Write-Host "[1/4] Updating Git Submodules..." -ForegroundColor Yellow
    $stepStart = Get-Date
    $success = Invoke-UpdateSubmodules -CurrentProject $ProjectPath
    $submodulesTime = ((Get-Date) - $stepStart).TotalSeconds
    
    Write-Host "      Step completed in " -NoNewline -ForegroundColor DarkGray
    Write-Host (Format-ExecutionTime $submodulesTime) -ForegroundColor Cyan
    Write-Host ""
    
    if (-not $success) {
        Write-Host "❌ Combined operation failed at step 1 (Update Submodules)" -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    # Step 2: Generate Project Files
    Write-Host "[2/4] Generating Project Files..." -ForegroundColor Yellow
    $stepStart = Get-Date
    $success = Invoke-GenerateProjectFiles -Engine $Engine -ProjectPath $ProjectPath -Settings $Settings
    $generateTime = ((Get-Date) - $stepStart).TotalSeconds
    
    Write-Host "      Step completed in " -NoNewline -ForegroundColor DarkGray
    Write-Host (Format-ExecutionTime $generateTime) -ForegroundColor Cyan
    Write-Host ""
    
    if (-not $success) {
        Write-Host "❌ Combined operation failed at step 2 (Generate)" -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    # Step 3: Build Project
    Write-Host "[3/4] Building Project..." -ForegroundColor Yellow
    $stepStart = Get-Date
    $success = Invoke-BuildProject -Target $Target -Config $Config -Platform $Platform `
        -ProjectPath $ProjectPath -Engine $Engine -Settings $Settings
    $buildTime = ((Get-Date) - $stepStart).TotalSeconds
    
    Write-Host "      Step completed in " -NoNewline -ForegroundColor DarkGray
    Write-Host (Format-ExecutionTime $buildTime) -ForegroundColor Cyan
    Write-Host ""
    
    if (-not $success) {
        Write-Host "❌ Combined operation failed at step 3 (Build)" -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    # Step 4: Launch Editor
    Write-Host "[4/4] Launching Unreal Editor..." -ForegroundColor Yellow
    $stepStart = Get-Date
    $success = Invoke-LaunchEditor -EnginePath $Engine.Path -ProjectPath $ProjectPath
    $launchTime = ((Get-Date) - $stepStart).TotalSeconds
    
    Write-Host "      Step completed in " -NoNewline -ForegroundColor DarkGray
    Write-Host (Format-ExecutionTime $launchTime) -ForegroundColor Cyan
    Write-Host ""
    
    if (-not $success) {
        Write-Host "❌ Combined operation failed at step 4 (Launch Editor)" -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    # Success summary
    $totalTime = ((Get-Date) - $totalStartTime).TotalSeconds
    
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "✅ ALL STEPS COMPLETED SUCCESSFULLY!" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "Time Breakdown:" -ForegroundColor Yellow
    Write-Host "  Update Submodules: " -NoNewline -ForegroundColor Gray
    Write-Host (Format-ExecutionTime $submodulesTime) -ForegroundColor Cyan
    Write-Host "  Generate:          " -NoNewline -ForegroundColor Gray
    Write-Host (Format-ExecutionTime $generateTime) -ForegroundColor Cyan
    Write-Host "  Build:             " -NoNewline -ForegroundColor Gray
    Write-Host (Format-ExecutionTime $buildTime) -ForegroundColor Cyan
    Write-Host "  Launch Editor:     " -NoNewline -ForegroundColor Gray
    Write-Host (Format-ExecutionTime $launchTime) -ForegroundColor Cyan
    Write-Host "  " -NoNewline
    Write-Host "─────────────────────" -ForegroundColor DarkGray
    Write-Host "  Total:             " -NoNewline -ForegroundColor Yellow
    Write-Host (Format-ExecutionTime $totalTime) -ForegroundColor Cyan
    Write-Host ""

    # Save to history
    Add-CombinedCommandToHistory -Target $Target -Config $Config -Platform $Platform `
        -ProjectPath $ProjectPath -Engine $Engine -Settings $Settings `
        -SubmodulesTime $submodulesTime -GenerateTime $generateTime -BuildTime $buildTime -TotalTime $totalTime

    Read-Host "Press Enter to continue"
}

function Get-UnrealBuildToolPath {
    param([string]$EnginePath)
    
    $ubtPath = Join-Path $EnginePath "Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.exe"
    
    if (-not (Test-Path $ubtPath)) {
        $ubtPath = Join-Path $EnginePath "Engine\Binaries\DotNET\UnrealBuildTool.exe"
    }
    
    if (Test-Path $ubtPath) {
        return $ubtPath
    }
    
    return $null
}

function Invoke-UnrealBuildTool {
    param(
        [string]$EnginePath,
        [string]$Arguments,
        [switch]$ShowOutput
    )
    
    $ubtPath = Get-UnrealBuildToolPath $EnginePath
    
    if (-not $ubtPath) {
        Write-Host "UnrealBuildTool not found!" -ForegroundColor Red
        return $false
    }
    
    # Simple approach - just run the process and let output flow to console
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ubtPath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.WaitForExit()
    
    return $process.ExitCode -eq 0
}

function Invoke-LaunchEditor {
    param(
        [string]$EnginePath,
        [string]$ProjectPath
    )
    
    Write-Host ""
    Write-Host "Launching Unreal Editor..." -ForegroundColor Yellow
    
    # Find editor executable (UE5 uses UnrealEditor.exe, UE4 uses UE4Editor.exe)
    $editorPath = Join-Path $EnginePath "Engine\Binaries\Win64\UnrealEditor.exe"
    
    if (-not (Test-Path $editorPath)) {
        $editorPath = Join-Path $EnginePath "Engine\Binaries\Win64\UE4Editor.exe"
    }
    
    if (-not (Test-Path $editorPath)) {
        Write-Host "Editor executable not found!" -ForegroundColor Red
        return $false
    }
    
    Write-Host ""
    Write-Host "Command: " -NoNewline -ForegroundColor Gray
    Write-Host ('"' + $editorPath + '" "' + $ProjectPath + '"') -ForegroundColor Cyan
    Write-Host ""
    
    try {
        # Launch editor as a new process (don't wait for it to exit)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $editorPath
        $psi.Arguments = '"' + $ProjectPath + '"'
        $psi.UseShellExecute = $true
        $psi.CreateNoWindow = $false
        
        [void][System.Diagnostics.Process]::Start($psi)
        
        Write-Host "Editor launched successfully!" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "Failed to launch editor: $_" -ForegroundColor Red
        return $false
    }
}

function Show-SwitchEngineMenu {
    param(
        [Parameter(Mandatory)]
        [ref]$CurrentEngine,
        [Parameter(Mandatory)]
        [array]$AvailableEngines,
        [string]$CurrentProject
    )
    
    if (-not $CurrentProject) {
        Write-Host "No project!" -ForegroundColor Red
        Start-Sleep -Seconds 1
        return
    }
    
    Clear-Host
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  SELECT ENGINE" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    $engines = $AvailableEngines | Sort-Object { if ($_.Source -eq "Launcher") { 0 } else { 1 } }, Version -Descending
    
    for ($i = 0; $i -lt [Math]::Min(9, $engines.Count); $i++) {
        $e = $engines[$i]
        $current = if ($CurrentEngine.Value -and $e.Version -eq $CurrentEngine.Value.Version) { " (current)" } else { "" }
        Write-Host "  [$($i + 1)] $($e.Version) ($($e.Source))$current" -ForegroundColor Cyan
        Write-Host "      $($e.Path)" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  [ESC] Back" -ForegroundColor Gray
    Write-Host ""
    
    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    
    if ($key.VirtualKeyCode -eq 27) { 
        return 
    }
    
    $keyChar = $key.Character.ToString()
    if ($keyChar -match '^\d$') {
        $index = [int]$keyChar - 1
        if ($index -ge 0 -and $index -lt $engines.Count) {
            $engine = $engines[$index]
            $CurrentEngine.Value = $engine
            
            # Save engine association to .uproject file
            $success = Set-ProjectEngineAssociation -ProjectPath $CurrentProject -EngineAssociation $engine.Identifier
            
            Write-Host ""
            if ($success) {
                Write-Host "Switched to: $($engine.Version)" -ForegroundColor Green
                Write-Host "Saved association to project file" -ForegroundColor Green
            } else {
                Write-Host "Switched to: $($engine.Version)" -ForegroundColor Green
                Write-Host "Warning: Failed to save association to project file" -ForegroundColor Yellow
            }
            Start-Sleep -Seconds 2
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-GenerateProjectFiles',
    'Invoke-BuildProject',
    'Invoke-CleanProject',
    'Invoke-UpdateSubmodules',
    'Invoke-CombinedOperation',
    'Invoke-LaunchEditor',
    'Show-SwitchEngineMenu'
)
