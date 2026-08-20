# Claude Code PostToolUse hook: advisory hint when an .as edit LATCHES the result of an
# INTERNAL__ tag scan into a member or field.
#
# The rule it enforces is in CLAUDE.md ("Store-family handles: Acquire + Promise is the ONLY way
# to hold one"). INTERNAL__ scans answer "does it exist right now", and during a snapshot load the
# answer is no for most of the load. A caller that latches that answer holds an invalid handle
# forever and comes back structurally present but functionally dead — the dead-HUD / dead-panel
# bug class QA reports as "loading a save breaks the UI".
#
# ADVISORY ONLY. It always exits 0 and never blocks; it prints the promise-gated alternative.
# Override: set SKIP_PROMISE_GATE_HINT=1 to silence it.
#
# Allow-listed, per CLAUDE.md's stated set of legitimate callers — the ones that RE-RESOLVE on
# every use and treat invalid as "not yet":
#   1. per-tick processors                -> *_Processor*.as
#   2. per-draw debugger pages            -> Script/Debugger/**
#   3. the acquire/flush machinery        -> the file that DECLARES the INTERNAL__ function
#   4. lazy re-resolve accessors          -> the assignment sits under an Is_NOT_Valid guard on
#                                            the same target

$ErrorActionPreference = 'Stop'

function Exit-Quiet {
    exit 0
}

function Emit-Hint([string]$Text) {
    $payload = @{
        hookSpecificOutput = @{
            hookEventName     = 'PostToolUse'
            additionalContext = $Text
        }
    }
    $payload | ConvertTo-Json -Depth 5 -Compress | Write-Output
    exit 0
}

if ($env:SKIP_PROMISE_GATE_HINT -eq '1') { Exit-Quiet }

# ---- 1. Read hook payload --------------------------------------------------
try {
    $raw = [Console]::In.ReadToEnd()
    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) {
        $raw = $raw.Substring(1)
    }
    $payload = $raw | ConvertFrom-Json
} catch {
    Exit-Quiet  # malformed payload -> don't get in the way
}

$toolInput = $payload.tool_input
if (-not $toolInput) { Exit-Quiet }

$filePath = $toolInput.file_path
if (-not $filePath) { Exit-Quiet }
if ($filePath -notmatch '\.as$') { Exit-Quiet }

# ---- 2. What text did this edit ADD? ---------------------------------------
$addedParts = New-Object System.Collections.Generic.List[string]

if ($toolInput.PSObject.Properties.Name -contains 'content' -and $toolInput.content) {
    $addedParts.Add([string]$toolInput.content)
}
if ($toolInput.PSObject.Properties.Name -contains 'new_string' -and $toolInput.new_string) {
    $addedParts.Add([string]$toolInput.new_string)
}
if ($toolInput.PSObject.Properties.Name -contains 'edits' -and $toolInput.edits) {
    foreach ($edit in $toolInput.edits) {
        if ($edit.new_string) { $addedParts.Add([string]$edit.new_string) }
    }
}

if ($addedParts.Count -eq 0) { Exit-Quiet }

$added = $addedParts -join "`n"
if ($added -notmatch 'INTERNAL__') { Exit-Quiet }

# ---- 3. Allow-listed paths -------------------------------------------------
$normalized = ($filePath -replace '\\', '/')

if ($normalized -match '/Script/Debugger/') { Exit-Quiet }
if ($normalized -match '_Processor[^/]*\.as$') { Exit-Quiet }

# The feature that OWNS the scan is the acquire/flush machinery. A declaration is an INTERNAL__
# name that is NOT reached through a namespace — a call site always writes utils_x::INTERNAL__Y.
if (Test-Path -LiteralPath $filePath) {
    try {
        $onDisk = Get-Content -LiteralPath $filePath -Raw -ErrorAction Stop
        foreach ($diskLine in ($onDisk -split "`r?`n")) {
            if ($diskLine -match '::INTERNAL__') { continue }
            if ($diskLine -match '^\s*\S+\s+INTERNAL__\w+\s*\(') { Exit-Quiet }
        }
    } catch {
        # unreadable file -> fall through and judge on the edit text alone
    }
}

# ---- 4. Find latches in the added text -------------------------------------
# A latch ASSIGNS the scan result to something that outlives the statement. A DECLARATION
# (`auto X = ...`, `FCk_Handle_Y X = ...`) is the sanctioned re-resolve shape and is not one:
# its two leading tokens make it fail this pattern.
$lines = $added -split "`r?`n"
$findings = New-Object System.Collections.Generic.List[string]

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -notmatch 'INTERNAL__') { continue }

    $m = [regex]::Match($line, '^\s*(?<lhs>[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*=\s*[^=].*INTERNAL__')
    if (-not $m.Success) { continue }

    $lhs = $m.Groups['lhs'].Value

    # Lazy re-resolve accessor: the assignment is guarded by an invalidity check on the same
    # target, so the handle is re-resolved rather than trusted. CLAUDE.md names this shape.
    $guarded = $false
    $from = [Math]::Max(0, $i - 3)
    for ($j = $from; $j -lt $i; $j++) {
        if ($lines[$j] -match ('Is_NOT_Valid\(\s*' + [regex]::Escape($lhs) + '\s*\)')) {
            $guarded = $true
            break
        }
    }
    if ($guarded) { continue }

    $findings.Add("    $($line.Trim())")
}

if ($findings.Count -eq 0) { Exit-Quiet }

# ---- 5. Advise -------------------------------------------------------------
$leaf = Split-Path -Leaf $filePath
$body = @(
    "[promise-gate] $leaf latches an INTERNAL__ scan result into a member or field:",
    ($findings -join "`n"),
    '',
    'An INTERNAL__ scan answers "does it exist RIGHT NOW". During a snapshot load that answer is',
    'no for most of the load, so a latched handle stays invalid forever and the feature comes back',
    'structurally present but functionally dead. Acquire + Promise instead:',
    '',
    '    auto Pending = utils_store_driver::AcquireStoreDriver(Context);',
    '    Pending.Promise_OnStoreDriverReady(FBb_Delegate_StoreDriver_OnReady(this, n"OnReady"));',
    '    // ... then read InDriver.Get_Economy() / Get_OccupancySink() / Get_EmployeeManager() / ...',
    '',
    'Use Promise_OnSubordinatesReady for any consumer that must work on a CLIENT (a client never',
    'reaches Get_IsReady — discovery is authority-gated).',
    '',
    'Legitimate as-is if this caller RE-RESOLVES on every use and treats invalid as "not yet"',
    '(per-tick processor, per-draw debugger page, lazy re-resolve accessor, the acquire/flush',
    'machinery itself). Advisory only — nothing was blocked. Silence with SKIP_PROMISE_GATE_HINT=1.'
) -join "`n"

Emit-Hint $body
