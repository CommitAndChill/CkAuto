<#
.SYNOPSIS
    Advisory PostToolUse hook: flags edits that put non-ASCII or assistant-tool
    references back into the AngelScript sources that ship to players.

.DESCRIPTION
    The `Script` folder and the Script root of every enabled plugin are staged as
    loose source next to the shipped executable, so their contents are readable by
    anyone who owns the game. Two things therefore matter in those trees:

      * the text stays plain ASCII, and
      * nothing references assistant tooling or internal planning documents.

    This hook reads the PostToolUse payload on stdin, looks only at the file that
    was just edited, and prints guidance when that file regresses either rule. It
    is ADVISORY - it never blocks the edit. `CkAuto/Sanitize-ShippedScripts.py
    --apply` fixes the ASCII half automatically.

    Set SKIP_SHIPPED_SCRIPT_HINT=1 to silence it.
#>

if ($env:SKIP_SHIPPED_SCRIPT_HINT -eq '1') { exit 0 }

$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$path = $payload.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($path)) { exit 0 }
if (-not (Test-Path -LiteralPath $path)) { exit 0 }
if ($path -notmatch '\.(as|py)$') { exit 0 }

# Only the roots that actually ship.
$normalized = $path -replace '\\', '/'
$inShippedRoot = ($normalized -match '/Script/') -and (
    ($normalized -notmatch '/Plugins/') -or
    ($normalized -match '/Plugins/(CkFoundation|CkTests)/Script/')
)
if (-not $inShippedRoot) { exit 0 }

$lines = Get-Content -LiteralPath $path -Encoding UTF8
$findings = New-Object System.Collections.Generic.List[string]

# Player-facing prose is exempt: authored dialogue and localized UI text keep
# their typography on purpose.
$protectedFile = $normalized -match '/Speech/Banks/'

for ($i = 0; $i -lt $lines.Count; $i++)
{
    $line = $lines[$i]
    $num  = $i + 1

    if ($line -match 'CLAUDE\.md|Claude\.md|superpowers|CONTINUATION_PROMPT|\.claude/')
    {
        $findings.Add("  line ${num}: references assistant tooling or an internal planning doc")
        continue
    }

    if ($protectedFile -or $line -match 'NSLOCTEXT|LOCTEXT|FText|DisplayName') { continue }

    $nonAscii = ([char[]]$line | Where-Object { [int]$_ -gt 127 })
    if ($nonAscii.Count -gt 0)
    {
        $codes = ($nonAscii | Select-Object -Unique | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' '
        $findings.Add("  line ${num}: non-ASCII ($codes)")
    }
}

if ($findings.Count -eq 0) { exit 0 }

$leaf = Split-Path -Leaf $path
Write-Host ''
Write-Host "[shipped-script hygiene] $leaf ships to players as loose source."
foreach ($f in ($findings | Select-Object -First 8)) { Write-Host $f }
if ($findings.Count -gt 8) { Write-Host "  ... and $($findings.Count - 8) more" }
Write-Host '  Fix the ASCII findings with: python CkAuto/Sanitize-ShippedScripts.py --apply'
Write-Host '  (advisory only; SKIP_SHIPPED_SCRIPT_HINT=1 silences this)'

exit 0
