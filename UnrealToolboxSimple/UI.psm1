# ============================================================================
# UI.psm1 - UI helpers
# ============================================================================

function Read-SingleKey {
    param([int]$TimeoutMilliseconds = -1)
    
    if ($TimeoutMilliseconds -gt 0) {
        $startTime = Get-Date
        while (-not $Host.UI.RawUI.KeyAvailable) {
            $elapsed = ((Get-Date) - $startTime).TotalMilliseconds
            if ($elapsed -ge $TimeoutMilliseconds) {
                return $null
            }
            Start-Sleep -Milliseconds 50
        }
    }
    
    if ($Host.UI.RawUI.KeyAvailable) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return $key.Character
    }
    
    return $null
}

function Test-ProjectRunning {
    param([string]$ProjectPath)
    
    if (-not $ProjectPath) { return $false }
    
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    $editorProcessName = "UnrealEditor"
    
    $processes = Get-Process -Name $editorProcessName -ErrorAction SilentlyContinue
    
    foreach ($proc in $processes) {
        try {
            $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)").CommandLine
            if ($cmdLine -and $cmdLine -like "*$projectName*") {
                return $true
            }
        }
        catch {
            continue
        }
    }
    
    return $false
}

function Show-Confirmation {
    param(
        [string]$Message,
        [switch]$Dangerous
    )
    
    Write-Host ""
    Write-Host "  $Message " -NoNewline -ForegroundColor Yellow
    
    if ($Dangerous) {
        Write-Host "[Shift+Y]" -NoNewline -ForegroundColor Red
        Write-Host " Confirm  " -NoNewline
        Write-Host "[N]" -NoNewline -ForegroundColor Gray
        Write-Host " Cancel"
        
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return ($key.Character.ToString().ToUpper() -eq "Y" -and ($key.ControlKeyState -band 0x0010))
    } else {
        Write-Host "[Y]" -NoNewline -ForegroundColor Green
        Write-Host " Yes  " -NoNewline
        Write-Host "[N]" -NoNewline -ForegroundColor Gray
        Write-Host " Cancel" -ForegroundColor Gray
        Write-Host ""
        
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return $key.Character.ToString().ToUpper() -eq "Y"
    }
}

Export-ModuleMember -Function Read-SingleKey, Test-ProjectRunning, Show-Confirmation
