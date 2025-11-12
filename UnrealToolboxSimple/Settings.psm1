# ============================================================================
# Settings.psm1 - Project settings management
# ============================================================================

function Get-ProjectSettingsPath {
    param([string]$ProjectPath)
    
    $projectDir = Split-Path $ProjectPath
    $settingsDir = Join-Path $projectDir ".utoolbox"
    
    if (-not (Test-Path $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    }
    
    return Join-Path $settingsDir "settings.json"
}

function Load-ProjectSettings {
    param([string]$ProjectPath)
    
    $settingsPath = Get-ProjectSettingsPath $ProjectPath
    
    if (Test-Path $settingsPath) {
        try {
            $json = Get-Content $settingsPath -Raw | ConvertFrom-Json
            return @{
                build = @{
                    target = $json.build.target
                    config = $json.build.config
                    platform = $json.build.platform
                }
                combined = @{
                    updateSubmodules = if ($null -ne $json.combined.updateSubmodules) { $json.combined.updateSubmodules } else { $true }
                    generate = if ($null -ne $json.combined.generate) { $json.combined.generate } else { $true }
                    build = if ($null -ne $json.combined.build) { $json.combined.build } else { $true }
                    launch = if ($null -ne $json.combined.launch) { $json.combined.launch } else { $true }
                }
                history = @{
                    generate = @($json.history.generate)
                    build = @($json.history.build)
                    combined = @($json.history.combined)
                }
            }
        }
        catch {
            Write-Host "Failed to load settings: $_" -ForegroundColor Red
        }
    }
    
    # Default settings
    return @{
        build = @{
            target = "Editor"
            config = "Development"
            platform = "Win64"
        }
        combined = @{
            updateSubmodules = $true
            generate = $true
            build = $true
            launch = $true
        }
        history = @{
            generate = @()
            build = @()
            combined = @()
        }
    }
}

function Save-ProjectSettings {
    param(
        [string]$ProjectPath,
        [hashtable]$Settings
    )
    
    $settingsPath = Get-ProjectSettingsPath $ProjectPath
    
    try {
        $Settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath
    }
    catch {
        Write-Host "Failed to save settings: $_" -ForegroundColor Red
    }
}

Export-ModuleMember -Function Load-ProjectSettings, Save-ProjectSettings
