# Claude Code PreToolUse hook: blocks file-mutating git ops when this project's
# UnrealEditor is open AND the op would touch engine-locked paths.
#
# Tier behaviour (see .claude/plans/whenever-we-do-git-woolly-cray.md / CLAUDE.md):
#   editor closed                       -> exit 0 silently
#   editor open, source-only op         -> permissionDecision: "ask"  (soft warn)
#   editor open, engine-locked paths    -> permissionDecision: "deny" (hard warn)
#
# Override: set SKIP_UNREAL_GUARD=1 to short-circuit the guard.
#
# Editor detection ports the logic from
#   D:/Repos/FtxCatalyst/libs/UnrealKit/src/EditorDetection.cpp
# (probe Saved/Logs/*.log for an exclusive write lock — UE holds the active log
#  exclusively for the editor's lifetime; immune to renamed editor binaries.)

$ErrorActionPreference = 'Stop'

function Emit-Allow {
    exit 0
}

function Emit-Decision([string]$Decision, [string]$Reason) {
    $payload = @{
        hookSpecificOutput = @{
            hookEventName            = 'PreToolUse'
            permissionDecision       = $Decision
            permissionDecisionReason = $Reason
        }
    }
    $payload | ConvertTo-Json -Depth 5 -Compress | Write-Output
    exit 0
}

# ---- 1. Read hook payload --------------------------------------------------
try {
    $raw = [Console]::In.ReadToEnd()
    # Strip UTF-8 BOM if present (some pipe sources prepend one)
    if ($raw.Length -gt 0 -and [int][char]$raw[0] -eq 0xFEFF) {
        $raw = $raw.Substring(1)
    }
    $payload = $raw | ConvertFrom-Json
} catch {
    Emit-Allow  # malformed payload -> don't get in the way
}

$cmd = $payload.tool_input.command
if (-not $cmd) { Emit-Allow }

# ---- 2. Filter: only react to git mutating verbs ---------------------------
# Tokenize each pipeline segment and look for the FIRST non-flag token after
# `git` — that's the verb. Necessary to avoid false matches on verb-like words
# that appear inside string arguments (e.g. `git commit -m "fix git checkout"`
# would otherwise be misclassified as a checkout op).
$mutatingVerbs = @('checkout','switch','rebase','merge','reset','pull','clean','restore','cherry-pick','revert','am','mv','rm','stash')
$preVerbFlagsTakingValue = @('-C','-c','--git-dir','--work-tree','--namespace','--exec-path','--super-prefix')

function Get-GitMutatingVerb([string]$CommandLine) {
    $segments = $CommandLine -split '\s*(?:;|&&|\|\||\|)\s*'
    foreach ($seg in $segments) {
        if ($seg -notmatch '^\s*git(\s|$)') { continue }
        $rest = ($seg -replace '^\s*git\s+', '').Trim()
        if (-not $rest) { continue }
        $tokens = $rest -split '\s+'
        $i = 0
        while ($i -lt $tokens.Length) {
            $t = $tokens[$i]
            if ($script:preVerbFlagsTakingValue -contains $t) { $i += 2; continue }
            if ($t -match '^-') { $i += 1; continue }
            if ($script:mutatingVerbs -contains $t) { return $t }
            # First non-flag token wasn't mutating; stop scanning this segment.
            break
        }
    }
    return $null
}

$verb = Get-GitMutatingVerb $cmd
if (-not $verb) { Emit-Allow }

# `git stash` only mutates the working tree on pop/apply
if ($verb -eq 'stash' -and $cmd -notmatch '\bstash\s+(pop|apply)\b') { Emit-Allow }

# Override env var
if ($env:SKIP_UNREAL_GUARD -eq '1') { Emit-Allow }

# ---- 3. Locate project root -----------------------------------------------
$projectRoot = $env:CLAUDE_PROJECT_DIR
if (-not $projectRoot -or -not (Test-Path $projectRoot)) {
    # Fallback: walk up from the script's own location until we find a .uproject
    $dir = Split-Path -Parent $PSCommandPath
    while ($dir -and -not (Get-ChildItem -LiteralPath $dir -Filter '*.uproject' -ErrorAction SilentlyContinue)) {
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { Emit-Allow }
        $dir = $parent
    }
    $projectRoot = $dir
}

# ---- 4. Editor-running probe (port of EditorDetection.cpp) ----------------
# Any exclusively-locked .log under this project's Saved/Logs means an editor
# for THIS project is running. UE keeps its active log file under an exclusive
# write lock for the editor's lifetime. We do NOT scan process names — custom
# engine forks rename the editor binary, so process-name scans produce both
# false positives (other projects) and false negatives (renamed binary).
function Test-EditorRunning([string]$Root) {
    $logsDir = Join-Path $Root 'Saved/Logs'
    if (-not (Test-Path -LiteralPath $logsDir)) { return $false }

    $logs = Get-ChildItem -LiteralPath $logsDir -Filter '*.log' -File -ErrorAction SilentlyContinue
    foreach ($log in $logs) {
        try {
            $fs = [System.IO.File]::Open(
                $log.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
            $fs.Close()
        } catch {
            return $true
        }
    }
    return $false
}

if (-not (Test-EditorRunning $projectRoot)) { Emit-Allow }

# ---- 5. Engine-locked path predicate (port of EditorGuard.hpp) ------------
function Test-EngineLockedPath([string]$Path) {
    if (-not $Path) { return $false }
    $p = $Path -replace '\\', '/'

    # Engine-locked extensions
    if ($p -match '\.(uasset|umap|ubulk|uexp|uptnl)$') { return $true }

    # Top-level engine-locked directories
    if ($p -imatch '^(Content|Binaries|Saved|Intermediate|DerivedDataCache)/') { return $true }

    # Plugin engine-locked subdirectories
    if ($p -imatch '^Plugins/[^/]+/(Content|Binaries|Intermediate)/') { return $true }

    return $false
}

# ---- 6. Enumerate affected paths for this op ------------------------------
# Submodule-aware: a command like `cd Plugins/Foo && git checkout dev` runs in
# the submodule's repo, not BB's. We resolve the operation's effective cwd from
# any leading `cd <path>` prefix, then use `git rev-parse --show-toplevel` from
# there to find the actual repo root (which may be a submodule). Paths
# enumerated by git are submodule-relative; we prefix them with the submodule's
# offset under BB before classification, so the engine-locked predicate (which
# expects BB-root-relative paths like `Plugins/Foo/Content/Bar.uasset`) works.

function Get-CommandCwd([string]$CommandLine, [string]$DefaultCwd) {
    if ($CommandLine -match '^\s*\(?\s*cd\s+(?:"([^"]+)"|''([^'']+)''|(\S+))\s*(?:&&|;)') {
        $path = if ($matches[1]) { $matches[1] } elseif ($matches[2]) { $matches[2] } else { $matches[3] }
        if ([System.IO.Path]::IsPathRooted($path)) { return $path }
        return (Join-Path $DefaultCwd $path)
    }
    return $DefaultCwd
}

function Get-GitToplevel([string]$Cwd) {
    if (-not (Test-Path -LiteralPath $Cwd)) { return $null }
    Push-Location $Cwd
    try {
        $top = & git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $top) { return $null }
        return ($top -replace '\\','/').Trim()
    } finally {
        Pop-Location
    }
}

function Invoke-Git([string[]]$GitArgs, [string]$WorkingDir) {
    Push-Location $WorkingDir
    try {
        $out = & git @GitArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ,@($out)  # always return an array, even for single-line/empty output
    } finally {
        Pop-Location
    }
}

# Pull the first non-flag argument after the verb as the ref / target
function Get-RefArg([string]$CommandLine, [string]$Verb) {
    $afterVerb = $CommandLine -replace ".*\bgit\s+(?:[^;&|]*?\s)?$Verb\s*", ''
    $tokens = @($afterVerb -split '[\s;&|]+' | Where-Object { $_ -and ($_ -notmatch '^-') })
    if ($tokens.Count -gt 0) { return $tokens[0] }
    return $null
}

# Resolve effective repo root and its offset relative to BB root
$opCwd = Get-CommandCwd $cmd $projectRoot
$gitTop = Get-GitToplevel $opCwd
if (-not $gitTop) { $gitTop = $projectRoot }
$projectRootNorm = ($projectRoot -replace '\\','/').TrimEnd('/')
$gitTopNorm = $gitTop.TrimEnd('/')
$pathPrefix = ''
if ($gitTopNorm -ne $projectRootNorm -and $gitTopNorm.ToLower().StartsWith(($projectRootNorm + '/').ToLower())) {
    $pathPrefix = $gitTopNorm.Substring($projectRootNorm.Length + 1) + '/'
}

$affected = $null
$enumerationFailed = $false

switch ($verb) {
    { $_ -in 'checkout','switch' } {
        # New-branch creation: `git checkout -b/-B NAME` or `git switch -c/-C NAME`.
        # Without a start_point, this just creates a ref pointing at HEAD —
        # zero working-tree changes, no asset risk. Silent pass even with the
        # editor open. With a start_point, fall through and enumerate against
        # that start_point (NOT against the new branch name, which doesn't
        # exist yet).
        $createFlag = if ($verb -eq 'checkout') { '[bB]' } else { '[cC]' }
        if ($cmd -match "\bgit\s+(?:[^;&|]*?\s)?$verb\s.*?-$createFlag\s+\S+(?:\s+(\S+))?") {
            $startPoint = $matches[1]
            if (-not $startPoint -or $startPoint -match '^-') {
                # Pure ref creation at HEAD; nothing to enumerate.
                Emit-Allow
            }
            $ref = $startPoint
        } else {
            $ref = Get-RefArg $cmd $verb
        }
        if ($ref) { $affected = Invoke-Git @('diff','--name-only','HEAD',$ref) $gitTop }
        if ($null -eq $affected) { $enumerationFailed = $true }
    }
    { $_ -in 'merge','rebase' } {
        $ref = Get-RefArg $cmd $verb
        if ($ref) { $affected = Invoke-Git @('diff','--name-only',"HEAD...$ref") $gitTop }
        if ($null -eq $affected) { $enumerationFailed = $true }
    }
    'reset' {
        $ref = Get-RefArg $cmd $verb
        $list = $null
        if ($ref) {
            $a = Invoke-Git @('diff','--name-only','HEAD',$ref) $gitTop
            if ($null -ne $a) { if ($null -eq $list) { $list = @() }; $list += $a }
        }
        $b = Invoke-Git @('diff','--name-only') $gitTop
        if ($null -ne $b) { if ($null -eq $list) { $list = @() }; $list += $b }
        if ($null -eq $list) { $enumerationFailed = $true } else { $affected = $list }
    }
    'pull' {
        $affected = Invoke-Git @('diff','--name-only','HEAD..@{upstream}') $gitTop
        if ($null -eq $affected) { $enumerationFailed = $true }
    }
    'stash' {
        # `git stash pop` / `git stash apply` default to stash@{0}, but accept
        # an explicit ref like `git stash pop stash@{2}` or `git stash pop 2`.
        # Pull the trailing token if it looks like a stash ref.
        $stashRef = $null
        if ($cmd -match '\bstash\s+(?:pop|apply)\b\s*([^\s;&|]+)') {
            $candidate = $matches[1]
            if ($candidate -match '^(stash@\{[^}]+\}|\d+)$') { $stashRef = $candidate }
        }
        $stashArgs = @('stash','show','--name-only')
        if ($stashRef) { $stashArgs += $stashRef }
        $affected = Invoke-Git $stashArgs $gitTop
        if ($null -eq $affected) { $enumerationFailed = $true }
    }
    'clean' {
        $dryRun = Invoke-Git @('clean','-nd') $gitTop
        if ($null -ne $dryRun) {
            $affected = $dryRun | ForEach-Object { ($_ -replace '^Would (remove|skip repository)\s+', '').Trim() } | Where-Object { $_ }
        } else {
            $enumerationFailed = $true
        }
    }
    'restore' {
        $afterVerb = $cmd -replace '.*\bgit\s+(?:[^;&|]*?\s)?restore\s*', ''
        $affected = $afterVerb -split '[\s;&|]+' | Where-Object { $_ -and ($_ -notmatch '^-') }
        if (-not $affected) { $enumerationFailed = $true }
    }
    { $_ -in 'cherry-pick','revert' } {
        $ref = Get-RefArg $cmd $verb
        if ($ref) { $affected = Invoke-Git @('diff','--name-only',"$ref^..$ref") $gitTop }
        if ($null -eq $affected) { $enumerationFailed = $true }
    }
    default {
        # mv, rm, am — paths are op-specific and parsing is unreliable. Treat
        # as enumeration failure so we err on the safe side.
        $enumerationFailed = $true
    }
}

# Map submodule-relative paths back to BB-root-relative for classification
if ($pathPrefix -and $affected) {
    $affected = @($affected | ForEach-Object { $pathPrefix + $_ })
}

# ---- 7. Classify and emit decision ----------------------------------------
if ($enumerationFailed) {
    Emit-Decision 'deny' (
        "UnrealEditor is open for this project AND the affected paths for ``git $verb`` could not be enumerated. " +
        "Assuming worst case: this op may touch engine-locked files (.uasset/.umap/Content/Binaries/etc) that the editor has open, which can corrupt assets. " +
        "Please ask the user to close the Unreal Editor and retry. " +
        "Override: set SKIP_UNREAL_GUARD=1 if you're sure."
    )
}

$locked = @()
foreach ($path in @($affected)) {
    if (Test-EngineLockedPath $path) { $locked += $path }
}

if ($locked.Count -eq 0) {
    Emit-Decision 'ask' (
        "UnrealEditor is open for this project, but ``git $verb`` only touches source/config files (no .uasset/.umap/Content/Binaries). " +
        "This should be safe — confirm with the user before proceeding."
    )
}

$sample = $locked | Select-Object -First 5
$more = if ($locked.Count -gt 5) { " (+ $($locked.Count - 5) more)" } else { '' }
Emit-Decision 'deny' (
    "UnrealEditor is open for this project AND ``git $verb`` will touch $($locked.Count) engine-locked file(s) that the editor has open: " +
    ($sample -join ', ') + $more + ". " +
    "Proceeding will likely corrupt assets. Please ask the user to close the Unreal Editor and retry. " +
    "Override (use only if you know the affected assets aren't loaded): set SKIP_UNREAL_GUARD=1."
)
