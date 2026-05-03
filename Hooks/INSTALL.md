# Installing the "block git ops while UnrealEditor is open" hook

This guard intercepts file-mutating git commands (`checkout`, `switch`, `rebase`,
`merge`, `reset`, `pull`, `clean`, `restore`, `cherry-pick`, `revert`,
`stash pop/apply`) issued by Claude Code when the project's UnrealEditor is open
and the operation would touch engine-locked paths (`.uasset`/`.umap`/`Content/`/
`Binaries/`/`Saved/`/`Intermediate/`/`DerivedDataCache/`/`Plugins/*/{Content,Binaries,Intermediate}/`).

The script (`Check-UnrealNotRunning.ps1`) lives in this submodule (`CkAuto/`) and
is project-agnostic. To install in a new UE project, do these two steps once.

## 1. Add the PreToolUse hook to `.claude/settings.json`

Inside the project's `.claude/settings.json`, add a `PreToolUse` block alongside
any existing hook entries:

```json
"PreToolUse": [
  {
    "matcher": "Bash",
    "hooks": [
      {
        "type": "command",
        "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"${CLAUDE_PROJECT_DIR}/CkAuto/Check-UnrealNotRunning.ps1\"",
        "timeout": 5
      }
    ]
  }
]
```

`${CLAUDE_PROJECT_DIR}` resolves to the project root, and `CkAuto/` is the
submodule path — so this works unchanged across projects.

## 2. Document the guard in the project's `CLAUDE.md`

Append this section so anyone reading the project guide knows what the guard
does and how to override it:

```markdown
## Hooks / safety guards

`.claude/settings.json` registers a `PreToolUse` hook (`CkAuto/Check-UnrealNotRunning.ps1`) that intercepts file-mutating git commands (`checkout`, `switch`, `rebase`, `merge`, `reset`, `pull`, `clean`, `restore`, `cherry-pick`, `revert`, `stash pop/apply`). Behaviour:

- **Editor closed for this project** → silent pass.
- **Editor open, op only touches source/config** → soft-warn prompt (`permissionDecision: "ask"`); user confirms or declines.
- **Editor open, op touches engine-locked paths** (`.uasset`/`.umap`/`Content/`/`Binaries/`/`Saved/`/`Intermediate/`/`DerivedDataCache/`/`Plugins/*/{Content,Binaries,Intermediate}/`) → hard block (`permissionDecision: "deny"`), enforced even in `--dangerously-skip-permissions` mode.

Detection is per-project: probes `Saved/Logs/*.log` for an exclusive write lock (UE holds the active log exclusively while running). Other UE instances open for unrelated projects do not trip the guard, and renamed editor binaries don't matter (no process-name scan).

Submodule-aware: commands like `cd Plugins/Foo && git checkout <ref>` are recognised — the script resolves the effective repo root via `git rev-parse --show-toplevel`, enumerates against that repo, and prefixes the resulting paths with the submodule's offset under the project root before classification.

**Limitation — submodule-rooted sessions:** the hook is wired through `<project>/.claude/settings.json`, which Claude Code only loads when the session's project root *is* the project. If you launch Claude Code from inside a submodule, our hook is not active. Workarounds: (a) launch Claude Code from the project root for any session that may do git ops, or (b) add a personal `~/.claude/settings.json` invoking a copy of the script kept somewhere stable outside the repo — note this only protects you, not teammates.

Override for the deny tier: `SKIP_UNREAL_GUARD=1`. Use only when you know the affected assets aren't loaded in the editor — the natural recovery is to close the editor and retry.
```

## Updating the script

The script lives at `CkAuto/Check-UnrealNotRunning.ps1` in this submodule. To
ship a fix or improvement to all projects:

1. Edit and commit inside the `CkAuto` submodule.
2. Push to `origin/dev` (the CkAuto repo).
3. In each consuming project, `git submodule update --remote CkAuto` (or
   equivalent) to pick up the new commit, then commit the bumped pointer.

## Override env var

Set `SKIP_UNREAL_GUARD=1` in the shell to short-circuit the guard for the
current session. Intended only for the rare case where you know the affected
assets aren't actually loaded in the editor — the natural recovery is to close
the editor.
