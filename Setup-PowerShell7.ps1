# ============================================================================
# Setup-PowerShell7.ps1
# Installs PowerShell 7 and configures context menu options
# author: eterna1_0blivion & soredake
# ============================================================================

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    
    # Re-launch as administrator
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"" + $MyInvocation.MyCommand.Path + "`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    
    # Exit the non-elevated instance
    Exit
}

# Now running as Administrator
Clear-Host
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PowerShell 7 Setup & Configuration" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Running with administrator privileges" -ForegroundColor Green
Write-Host ""

# ============================================================================
# Step 1: Check if PowerShell 7 is installed
# ============================================================================

Write-Host "[Step 1/2] Checking PowerShell 7 installation..." -ForegroundColor Yellow

$pwsh7Path = "C:\Program Files\PowerShell\7\pwsh.exe"
$isPwsh7Installed = Test-Path $pwsh7Path

if ($isPwsh7Installed) {
    Write-Host "[OK] PowerShell 7 is already installed" -ForegroundColor Green
    
    # Get version
    try {
        $version = & $pwsh7Path --version
        Write-Host "     Version: $version" -ForegroundColor Gray
    } catch {
        Write-Host "     (Unable to determine version)" -ForegroundColor Gray
    }
} else {
    Write-Host "[!] PowerShell 7 is not installed" -ForegroundColor Red
    Write-Host ""
    Write-Host "Installing PowerShell 7 using winget..." -ForegroundColor Yellow
    Write-Host ""
    
    # Check if winget is available
    $wingetPath = Get-Command winget -ErrorAction SilentlyContinue
    
    if (-not $wingetPath) {
        Write-Host "Error: winget is not available on this system." -ForegroundColor Red
        Write-Host "Please install PowerShell 7 manually from:" -ForegroundColor Yellow
        Write-Host "https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Cyan
        Write-Host ""
        Read-Host "Press Enter to exit"
        Exit
    }
    
    # Install PowerShell 7 using winget
    Write-Host "Running: winget install Microsoft.PowerShell --silent" -ForegroundColor Gray
    Write-Host ""
    
    $installProcess = Start-Process winget -ArgumentList "install", "Microsoft.PowerShell", "--silent", "--accept-source-agreements", "--accept-package-agreements" -Wait -PassThru -NoNewWindow
    
    if ($installProcess.ExitCode -eq 0) {
        Write-Host ""
        Write-Host "[OK] PowerShell 7 installed successfully!" -ForegroundColor Green
        
        # Verify installation
        if (Test-Path $pwsh7Path) {
            Write-Host "[OK] Installation verified at: $pwsh7Path" -ForegroundColor Green
        } else {
            Write-Host "[!] PowerShell 7 may have been installed, but cannot verify" -ForegroundColor Yellow
        }
    } else {
        Write-Host ""
        Write-Host "[ERROR] PowerShell 7 installation failed (Exit code: $($installProcess.ExitCode))" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please try installing manually from:" -ForegroundColor Yellow
        Write-Host "https://github.com/PowerShell/PowerShell/releases" -ForegroundColor Cyan
        Write-Host ""
        Read-Host "Press Enter to exit"
        Exit
    }
}

Write-Host ""

# ============================================================================
# Step 2: Configure PowerShell Context Menu
# ============================================================================

Write-Host "[Step 2/2] Configuring PowerShell context menu..." -ForegroundColor Yellow
Write-Host ""

# Get path to the registry file
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$regFile = Join-Path $scriptPath "Common\context_pwsh_fix.reg"

# Check if the file exists
if (-not (Test-Path $regFile)) {
    Write-Host "Error: Registry file not found at $regFile" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    Exit
}

Write-Host "Importing registry file: $regFile" -ForegroundColor Gray
Write-Host ""

reg import "$regFile"

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "[OK] Registry settings imported successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Context menu options added:" -ForegroundColor Gray
    Write-Host "  - Run with PowerShell 7" -ForegroundColor Gray
    Write-Host "  - Run with PowerShell 7 as Admin" -ForegroundColor Gray
    Write-Host "  - Run with PowerShell 5" -ForegroundColor Gray
    Write-Host "  - Run with PowerShell 5 as Admin" -ForegroundColor Gray
    Write-Host "  - Edit with ISE" -ForegroundColor Gray
    Write-Host ""
    
    # Restart Explorer to apply changes immediately
    Write-Host "Restarting Windows Explorer to apply changes..." -ForegroundColor Yellow
    try {
        Stop-Process -Name explorer -Force -ErrorAction Stop
        Start-Sleep -Milliseconds 500
        Start-Process explorer.exe
        Write-Host "[OK] Explorer restarted successfully!" -ForegroundColor Green
    } catch {
        Write-Host "[!] Could not restart Explorer automatically: $_" -ForegroundColor Yellow
        Write-Host "    You may need to restart your computer for changes to take effect." -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "[ERROR] Registry import failed (Exit code: $LASTEXITCODE)" -ForegroundColor Red
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Setup Complete!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Right-click any .ps1 file to see the new PowerShell options!" -ForegroundColor Yellow
Write-Host ""

Read-Host "Press Enter to exit"
Exit
