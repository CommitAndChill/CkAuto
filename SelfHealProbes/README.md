# AS self-heal integration probes

End-to-end regression tests for the **AS bootstrap self-heal dispatcher** in
`Plugins/CkFoundation/Source/CkAngelscriptGenerator/SelfHeal/`. Per-strategy
synthesis logic is covered by unit tests under that module; the probes here
cover the **orchestration** (cycle counter, regen gating, PostCompile
ordering, ticker-vs-modal-tick routing, multi-strategy interaction) that
unit tests can't see because there's no real editor lifecycle.

This suite is **project-agnostic**. All BB-specific values (project name,
log paths, drift targets) are discovered at runtime — the same scripts run
unmodified against any Ck project that consumes the `CkAuto` submodule. The
expected install location is `CkAuto/SelfHealProbes/` at the project root, so
project root is `$PSScriptRoot/../..` from every script.

Each probe pairs a `*_corrupt.bat` / `*_restore.bat` (thin wrappers) with a
`.ps1` helper that does the work. A shared `_probe_verify.ps1` greps the
editor log for an ordered sequence of expected events and reports per-event
PASS/FAIL.

## Suite

| Probe | Flow | What it exercises |
|---|---|---|
| `_probe_merge_conflict.{bat,_restore.bat}` | Cold-start, bootstrap modal-tick drain | Up to three simultaneous drifts (AssetRegistry + DynamicHandle + EntitySpawnParams) resolved in a single bootstrap cycle, followed by PostCompile canonical regen + stub cleanup. Each strategy independently skips if no callable target exists. |
| `_probe_mid_session_add.{bat,_restore.bat}` | Mid-session, FTSTicker drain | A new `.as` file referencing up to three unresolved symbols dropped at runtime; mid-session ticker fires strategies across multiple cycles as hot-reload retries surface each error. |
| `_probe_tier3_{corrupt.bat,restore.bat}` | Tier 3 refusal validation | Calls a deliberately-fake asset accessor. Validates the post-2026-05-13 dispatcher behavior: Tier 1/2 fail → Tier 3 refuses → actionable banner surfaces instead of editor wedging on a parser-blind derivative error. |

## Runtime discovery

Probes resolve everything from on-disk state:

- **Project name + root**: walk up two levels from script location, find the `.uproject`, use its stem.
- **Log location**: `Saved/Logs/<ProjectName>*.log` glob — covers both default and `-ABSLOG=...` launches.
- **Editor-running check**: any `<ProjectName>*.log` with an exclusive write lock means the editor is up.
- **Merge-conflict targets** — for each strategy, the picker only selects targets that have at least one referencing AS caller under `Script/` (excluding `Script/Generated/`). Without an active caller, the drift wouldn't trigger an AS compile error and the dispatcher would never see it:
  - **AR**: first `TSoftObjectPtr<X> Name()` accessor in any `Script/Generated/*Assets.as` that's also called as `assets::Name(` or `assets::load::Name(` somewhere.
  - **DH**: first `HandleTypes[]` entry from `Script/Generated/DynamicHandleTypes.json` whose `TypeName` or `As_<ShortName>(` is referenced.
  - **ESP**: first `^namespace U\w+` block from any `Script/Generated/*_EntitySpawnParams.as` whose `::Params(` is called.
- **Mid-session asset folder**: parses `// Discovery root: /Game/<X>/` headers from `*Assets.as` and maps to `Content/<X>/` disk paths. The picker skips `_BP` / `_BP_C` suffixes because Blueprint assets often have unresolvable parent classes that defeat Tier 1/2 synthesis and (correctly) hit the Tier 3 refusal — that's correct dispatcher behavior but defeats the probe's AR strategy. Plugin mounts (`/CkTests/` etc.) are skipped because their disk paths are harder to resolve and they often live outside the project's authoring scope.
- **Mid-session class + handle names**: timestamped per run (`UCk_ProbeMidSession<yyMMddHHmmss>_EntityScript`, `FCk_Handle_ProbeMidSession<yyMMddHHmmss>`). Leftover AS registrations from prior probe runs in the same editor session — or stale entries in `DynamicHandleTypes.json` carried across launches — would otherwise satisfy the reference and silently skip DH/ESP synthesis.
- **Sidecar JSON**: each probe writes a sidecar recording its runtime picks; the verifier reads it to build dynamic expected-event lists. If a strategy was skipped, the corresponding events are dropped from the expectation.

## Running

```cmd
:: Probe A (cold-start) — editor MUST be closed
CkAuto\SelfHealProbes\_probe_merge_conflict.bat
:: launch <ProjectName>Editor.exe, wait for main screen
pwsh CkAuto\SelfHealProbes\_probe_verify.ps1 merge_conflict
CkAuto\SelfHealProbes\_probe_merge_conflict_restore.bat

:: Probe B (mid-session) — editor MUST be running
CkAuto\SelfHealProbes\_probe_mid_session_add.bat
:: wait 30s–5min for mid-session ticker to drain all strategies
pwsh CkAuto\SelfHealProbes\_probe_verify.ps1 mid_session_add
CkAuto\SelfHealProbes\_probe_mid_session_add_restore.bat

:: Probe Tier 3 — editor MUST be closed
CkAuto\SelfHealProbes\_probe_tier3_corrupt.bat
:: launch editor, observe the refusal banner + Slate toast
pwsh CkAuto\SelfHealProbes\_probe_verify.ps1 tier3
CkAuto\SelfHealProbes\_probe_tier3_restore.bat
```

The verifier accepts:
- `-LogPath <file>` — target a specific log (e.g. when you used
  `-ABSLOG=...` on editor launch). Otherwise the newest
  `Saved/Logs/<ProjectName>*.log` by mtime is used.
- `-Tail` — live-tail mode. Scan existing log content for already-fired
  events, then follow the log for new lines and match the remaining events
  as they arrive. Useful for "launch editor in one shell, run verifier in
  another, watch the recovery unfold". Exits when all events match.

Verifier exit codes:
- `0` — all events matched (PROBE PASSED).
- `1` — at least one event missing (PROBE FAILED).
- `2` — usage error (no `.uproject` at project root, sidecar missing, log
  not found, etc.).

### Expected output snapshot (merge_conflict, 10/10 PASS)

```
Project: BusterBlock
Verifying against log: D:/Repos/BusterBlock/Saved/Logs/BusterBlock.log
Sidecar: 3 strategy/strategies drifted

[PASS] @ 2026.05.14-01.03.56:495 — OnReloadHadErrors fired (bootstrap mode) (anywhere)
[PASS] @ 2026.05.14-01.03.56:495 — Queued recovery action(s) for bootstrap modal-tick apply (anywhere)
[PASS] @ 2026.05.14-01.03.57:462 — Modal-tick deferred apply firing — draining N pending action(s) (anywhere)
[PASS] @ 2026.05.14-01.03.57:463 — DynamicHandle: synthesized JSON stub entry for 'FCk_Handle_CharacterAttachPoints' (anywhere)
[PASS] @ 2026.05.14-01.03.57:833 — Synthesized stub for UBb_CheckoutCounter_DepositOrchestrator_EntityScript::Params (anywhere)
[PASS] @ 2026.05.14-01.03.57:833 — Synthesized AssetRegistry stub for assets::TestItem_BB_IDA (anywhere)
[PASS] @ 2026.05.14-01.03.57:833 — Cycle N applied N strategy/strategies (bootstrap) (anywhere)
[PASS] @ 2026.05.14-01.04.09:614 — DynamicHandle deferred regen fired (PostCompile sibling-detect OR OnPostEngineInit deferred) (anywhere)
[PASS] @ 2026.05.14-01.04.44:578 — PostCompile settled (shader idle AND AR idle) — AssetRegistry regen firing (anywhere)
[PASS] @ 2026.05.14-01.04.03:325 — Self-heal stub file served its purpose — deleting: (anywhere)

VERDICT: 10 of 10 events matched. PROBE PASSED.
```

## Verifier contract

The verifier matches against the **exact** log strings emitted by the
dispatcher (`Plugins/CkFoundation/Source/CkAngelscriptGenerator/SelfHeal/CkAngelscriptGenerator_Dispatcher.cpp`)
and the post-compile module (`...CkAngelscriptGenerator_Module.cpp`). These
strings include Unicode em-dashes (U+2014) — copy them literally if you
extend the verifier. Per-event regexes use `\d+` for counts and `.+` for
paths/names that vary per run.

All events are **anywhere-search** (full-log scan, not cursor-forward). The
dispatcher emits per-strategy events in classifier-iteration order which
varies, and individual strategies may re-fire across multiple cycles during
mid-session. The semantic check is "did this event happen at least once?",
not "did this event happen in this exact order".

## Graceful skip for sparse projects

If a project doesn't have AR configs / dynamic handles / entity scripts yet
(e.g. fresh `CkPlugins`-style projects):

- **Merge-conflict**: each unavailable strategy logs `[SKIP] <strategy>` and
  is omitted from the sidecar's `Drifts` map. If all three skip, the probe
  writes an empty-Drifts sidecar and exits 0. Verifier reads the empty
  sidecar and reports `PROBE PASSED (no-op)`.
- **Mid-session-add**: omits the AR reference from the injected `.as` file
  if no `*Assets.as` files exist. Expects 2-symbol (class + handle) recovery
  in that case.
- **Tier 3**: project-agnostic by construction (uses a fake asset name).

## Runtime artifacts (gitignored at the consuming project's root)

The probes generate these during a run; they need ignore globs in each
consuming project's `.gitignore`:

```gitignore
# AS self-heal integration probes — runtime artifacts
*.assetsbak
*.handlebak
*.entitybak
Script/_[Pp]robe*.as
Script/_probe_*.targets.json
Script/Generated/_probe_*.targets.json
```

The `_StubRecovery_*` sibling files the dispatcher itself writes are
covered by a separate gitignore stanza alongside the `Script/Generated/`
tree.

## When to add a new probe

A new probe is warranted when:

1. A new dispatcher strategy lands and you want orchestration coverage for it.
2. A new orchestration mode lands (a third drain mechanism beyond
   modal-tick / FTSTicker, etc.).
3. A user-visible failure mode the dispatcher should recover from gets
   surfaced — write the probe first, then fix.

For per-strategy synthesis correctness, prefer unit tests under
`Plugins/CkFoundation/Source/CkAngelscriptGenerator/SelfHeal/Tests/` rather
than another probe — they're cheaper to run.

## Editor lifecycle gotchas

Worth knowing before running probes, especially for AI agents that don't
have eyes-on the editor window:

- **Editor binary is `<ProjectName>Editor.exe`** (e.g. `BusterBlockEditor.exe`,
  `CkPluginsEditor.exe`) under `<ProjectRoot>/Binaries/Win64/`, not the
  generic `UnrealEditor.exe`. `tasklist | grep -i unreal` MISSES it. Use
  `tasklist | grep -iE "<ProjectName>Editor|UnrealEditor"` instead.
- **Launching via shell `&` / `nohup` / Claude's `run_in_background:true`**
  reports a misleading exit code 1 within ~1s — the editor detaches from
  its parent shell on Windows. Don't act on the exit code; verify the
  process is alive via `tasklist`.
- **Editor-running check** in the probes uses an exclusive write-lock probe
  against `Saved/Logs/<ProjectName>*.log` (any file matching the glob being
  locked = editor up). Works regardless of process-name renames AND covers
  `-ABSLOG=<custom>.log` launches as long as the custom name still starts
  with `<ProjectName>`.
- **To stop the editor cleanly**:
  `pwsh -NoProfile -Command "Get-Process <ProjectName>Editor -ErrorAction SilentlyContinue | Stop-Process -Force"`,
  then a brief sleep + re-check `tasklist` to confirm gone.
- **Probe A vs Probe B vs Tier 3 editor-state requirements**:
  | Probe | Editor state at run time |
  |---|---|
  | merge_conflict | MUST be closed (probe refuses if log lock detected) |
  | mid_session_add | MUST be running (probe only warns, doesn't refuse) |
  | tier3 | MUST be closed (probe refuses; cold-start triggers the recovery path) |
- **Settle window**: after launching the editor for merge_conflict or
  tier3, wait until the editor's main viewport is visible — typically
  30–90s on a warm DDC, longer on first-build or shader compile. The
  verifier handles "wait for self-heal events" itself if you use `-Tail`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Probe corrupt script exits with "Editor appears to be running" | A `<Project>*.log` in `Saved/Logs/` is write-locked | Close the editor, retry. If no editor running, check for orphan `tail.exe`/`crashpad_handler.exe` processes holding stale log handles. |
| All three merge_conflict strategies `[SKIP]` | `Script/Generated/` empty or no AS callers reference the candidates | Expected for fresh projects without AR configs / dynamic handles / entity scripts. Probe writes empty-Drifts sidecar; verifier reports `PROBE PASSED (no-op)`. |
| Verifier exits 2 "Sidecar not found" | You're trying to verify before running the corrupt probe (or after running the restore) | Run the `_corrupt.bat`/`.ps1` first; the sidecar lives until the matching restore. |
| merge_conflict verifier reports 9/10 or fewer | Self-heal recovery hit a terminal banner or got stuck mid-flow | Inspect log for `[SelfHeal] AS compile failed with NO recognized root causes` (parser blind spot) or `Tier 3 UObject fallback is disabled` (asset UClass unresolvable). Both indicate dispatcher-side issues, not probe bugs. |
| mid_session_add picks a `*_BP` asset and AR refuses | Older probe version didn't filter Blueprints | Update CkAuto submodule — the picker skips `*_BP` / `*_BP_C` suffix conventions since they commonly fail Tier 1/2. |
| mid_session_add fires DH+ESP but NOT a brand-new DH (verifier reports stub-entry missing) | Class/handle name collision with leftover registration from a prior probe run in the same editor session | The current probe stamps class+handle names with `Get-Date -Format yyMMddHHmmss` per run. If you see this on a current version, file an issue — the stamp may have collided (rare). |
| Editor stuck on Hazelight modal forever | Self-heal exhausted cycles (bootstrap is capped at 3) or hit an unrecognized error pattern | Force-quit editor, manually inspect log around the last `[SelfHeal]` line, restore the probe drift via `_restore.bat`, relaunch. |
| Probe writes the `.as` file but mid-session ticker never fires | Editor's hot-reload thread didn't detect the file change (rare timing issue with -ABSLOG launches?) | Touch the file again: `(Get-Item Script/_probe_mid_session_add.as).LastWriteTime = Get-Date`. If still no ticker fire, the editor may be in a different AS state — close + cold-start instead. |

## Notes for AI agents driving this suite

If you're an agent picking up this suite for the first time:

1. **Read this README to the end** before invoking anything. The editor
   lifecycle requirements differ per probe (closed vs running) and getting
   that wrong wastes ~minutes per cycle.
2. **Resolve project name from the `.uproject`** in the project root
   (`Split-Path -Parent (Split-Path -Parent $PSScriptRoot)` from any probe
   script gives the project root). Don't hardcode `BusterBlock` — the suite
   runs in any Ck project.
3. **For probe A and tier3** the corrupt scripts refuse cleanly if the
   editor is up; treat that as a signal to stop the editor, not as a
   reason to override.
4. **Use `pwsh _probe_verify.ps1 <probe> -Tail`** as a single-command "do
   the verification thing" — it survives both before-and-after-recovery
   timing and tells you when to stop waiting.
5. **The dispatcher emits Unicode em-dashes (U+2014)** in several log
   strings. If you write new verifier patterns, copy them literally —
   normalizing to `-` breaks the match.
6. **Spawn an Explore subagent** to read
   `Plugins/CkFoundation/Source/CkAngelscriptGenerator/SelfHeal/CkAngelscriptGenerator_Dispatcher.cpp`
   if you need to understand WHY an event didn't fire — the dispatcher's
   classifier and apply-strategy switch are the source of truth for log
   line wording.
