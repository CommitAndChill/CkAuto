<#
.SYNOPSIS
Choose a clone-local Unreal build profile.
.DESCRIPTION
Status is read-only. SetProfile manages only this project's
DebugInfo XML setting, with an exact baseline snapshot for Default restoration.
Lean retains engine/compiler symbols and Windows link PDBs. No build or cleanup
is launched. Engine source capability is checked before setting Full or Lean.
.EXAMPLE
.\CkAuto\ProjectStorage.ps1 -Project . -Action SetProfile -Profile Lean
.EXAMPLE
.\CkAuto\ProjectStorage.ps1 -Project . -Action SetProfile -Profile Default
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$Project = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('Status','SetProfile')][string]$Action = 'Status',
    [ValidateSet('Lean','Full','Default')][string]$Profile,
    [string]$EngineRoot
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common\ProjectStorage.psm1') -Force -ErrorAction Stop
try {
    switch ($Action) {
        'Status' { Get-ProjectStorageStatus -Project $Project }
        'SetProfile' {
            if (-not $Profile) { throw '-Profile is required for SetProfile.' }
            Set-ProjectStorageProfile -Project $Project -Profile $Profile -EngineRoot $EngineRoot -WhatIf:$WhatIfPreference
        }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
