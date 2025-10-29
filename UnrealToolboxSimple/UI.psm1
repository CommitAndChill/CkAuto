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

Export-ModuleMember -Function Read-SingleKey, Test-ProjectRunning
