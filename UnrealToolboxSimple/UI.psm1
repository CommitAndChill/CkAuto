# ============================================================================
# UI.psm1 - UI helpers
# ============================================================================

function Read-SingleKey {
    param([int]$TimeoutMilliseconds = 0)
    
    if ($TimeoutMilliseconds -eq 0) {
        # Blocking - wait indefinitely
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        
        if ($key.VirtualKeyCode -eq 27 -or [int][char]$key.Character -eq 27) { 
            return 27 
        }
        if ($key.VirtualKeyCode -eq 13) { 
            return 13 
        }
        
        return $key.Character.ToString().ToUpper()
    }
    else {
        # Non-blocking with timeout
        $startTime = Get-Date
        
        do {
            if ([Console]::KeyAvailable) {
                $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                
                if ($key.VirtualKeyCode -eq 27 -or [int][char]$key.Character -eq 27) { 
                    return 27 
                }
                if ($key.VirtualKeyCode -eq 13) { 
                    return 13 
                }
                
                return $key.Character.ToString().ToUpper()
            }
            Start-Sleep -Milliseconds 50
            $elapsed = ((Get-Date) - $startTime).TotalMilliseconds
        } while ($elapsed -lt $TimeoutMilliseconds)
        
        return $null
    }
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
