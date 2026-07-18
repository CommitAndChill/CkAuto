---
name: build-test
description: Build the Unreal editor and run automation tests via UnrealToolbox (CkAuto). Use after writing C++ or AngelScript code in any project with a CkAuto/ folder to compile and verify it — never invoke Build.bat, UnrealBuildTool, or UnrealEditor-Cmd directly. Also covers process-level Gauntlet test runs (--gauntlet).
---

# Build & Test (Unreal Toolbox)

Compile the project's editor and run automation tests via UnrealToolbox to verify the C++ / Angelscript code you just wrote.

## Toolbox

Every CK-family project ships UnrealToolbox at `<project-root>/CkAuto/UnrealToolbox.exe`. Always invoke via the project-relative path so this skill works across any project that has the standard `CkAuto/` folder.

The toolbox handles engine resolution, plugin paths, and the UBT / automation invocation. **Do not** try to find UnrealBuildTool, the engine root, or the editor binary yourself — the whole point of the toolbox is that the agent shouldn't pick the wrong engine.

## Default flow: one single-shot invocation

The default is a **single** `--build --test` invocation writing **one** log (`Saved/Logs/BuildTest.log`). This is deliberate: the toolbox pops one LogViewer progress window at build start and reuses it through the test phase, so you watch the **entire** process — build → editor boot → tests — in one continuous window, with the build lines auto-colored as `msbuild` and the editor lines as `unreal` (segmented parsing). Two separate invocations would pop two sequential windows and split the log in two; use the [Separate-logs variant](#separate-logs-variant-two-invocations) below only when you specifically want the two logs apart.

## Pre-flight: wait if another editor is running

The toolbox spawns its own editor. If a different editor (another Claude session, a manually-opened editor, or a previous toolbox run that didn't shut down cleanly) is already up on the same project, two editors will fight over the same Saved/Intermediate directories and the build will fail in confusing ways. **Always run this check once before the single build+test invocation below (and before a Gauntlet run).**

The active editor holds an exclusive write lock on `<session-project-root>/Saved/Logs/<ProjectName>.log` (where `<ProjectName>` matches the `.uproject` filename — e.g. `CkPlugins.log`). Probe the lock:

```powershell
try { [IO.File]::Open('<session-project-root>/Saved/Logs/<ProjectName>.log', 'Open', 'Write', 'None').Close(); 'free' } catch { 'locked' }
```

If `'free'` (or the file doesn't exist) → proceed. If `'locked'` → another editor is up. **Wait it out** — do not kill the process, do not stomp the lock. Use a background `until ! <probe>; do sleep 60; done` loop so the wait is event-driven and you get a completion notification when it's free:

```bash
until ! powershell -NoProfile -Command "try { [IO.File]::Open('<session-project-root>/Saved/Logs/<ProjectName>.log', 'Open', 'Write', 'None').Close(); exit 0 } catch { exit 1 }"; do echo "$(date -u +%H:%M:%S) editor still up, sleeping 60s..."; sleep 60; done
```

Run that in the background with a generous timeout (10+ min). Don't poll yourself — wait for the completion notification, then proceed.

**Caveat:** if YOU are the one holding the lock from a still-running prior toolbox invocation that you started, the wait will never return — close the toolbox/editor first (or wait for it to finish) before starting a new one. The wait pattern is for *other* sessions or stale processes.

## Procedure

### Phase 1: Confirm config

If the user's request includes a config keyword, use it. Otherwise ask:

> "Which editor configuration — DebugGame Editor or Development Editor?"

| User says | Flag |
|---|---|
| `dev` / `development` | `--config=Development` |
| `debug` / `debuggame` | `--config=DebugGame` |

If unsure, default to **DebugGame** for code-fix iteration (faster link, debuggable symbols).

### Phase 2: Decide what to test

Single-shot needs the test pattern up front (both phases run in one command). Determine it in this order:

1. If the user passed a non-config token (e.g. `/build-test debug Goap`), use it verbatim.
2. Otherwise infer from your own recent edits: look at which Plugins / Source modules you touched. The substring of the module name is enough — `CkGoap` → `Goap`, `CkInventory` → `Inventory`.
3. If you can't infer, ask the user: "Test pattern? (e.g. `Goap`, `Inventory`, or `all`)".
4. For `all`, omit `--test-pattern` entirely so every project test runs.

**The matcher is forgiving**: case-insensitive substring tokens, any order. `Goap`, `cktests.GOAP`, and `goap.basicplan` all work. You don't need the full dotted test path.

### Phase 3: Build + test (single-shot)

**First run the Pre-flight editor-lock check** (see above) — once, before this invocation.

Run in the **background** — a CK-family editor build is 5-30 minutes. Use a 600000 ms (10 min) timeout, then await the completion notification. **Do not poll the log.**

The project root is the **primary working directory of the current session** — whatever repo Claude Code was launched from. However, if the changed files live in a *different* project (e.g. work was done in a sibling repo like BusterBlock while the session root is CkPlugins), build that project instead. Always `Set-Location` to the project being built explicitly before invoking the toolbox so the relative `./CkAuto/` and `--project=` paths resolve correctly.

```powershell
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --build --config=<Configuration> --target=Editor --test --test-pattern <Pattern> --output=Saved/Logs/BuildTest.log --project="<session-project-root>"
```

(Drop `--test-pattern` for the `all` case.) The test phase only runs if the build succeeded.

**Do NOT** pass `--generate` for normal iteration — it forces a project-files regeneration that adds time for no benefit. Use it only when a `*.Build.cs`, `*.uplugin`, or top-level source layout has changed since the previous build.

One progress LogViewer window opens at build start and is reused through the test phase (toolbox v1.15+), so the user watches build → editor boot → tests in a single window. Nothing to launch or wire — it's default-on whenever `--output` is set. On a true-headless / no-desktop machine (CI), add `--no-progress-window`.

### Phase 4: Report

Everything is in `Saved/Logs/BuildTest.log` — build output first, then the editor/test output.

- **Build failed** (non-zero exit with no `=== Test summary ===` block) → find the compile/link errors and stop; do not report test results that don't exist:
  ```powershell
  Select-String -Path "Saved\Logs\BuildTest.log" -Pattern "error C\d+|fatal error|LNK\d+|: error |^Error" | Select-Object -First 40
  ```
  Build logs run 50K+ lines — do **not** read the whole file.
- **Build succeeded** → read the **summary block** near the end:
  ```
  === Test summary ===
  Total: 2
  Passed: 2
  Failed: 0
  Skipped: 0
  Duration: 55s
  ```
  - **Exit 0** → green. Report ✅ `N passed` plus the duration.
  - **Non-zero with `Failed > 0`** → real test failures. Pull per-test details:
    ```powershell
    Select-String -Path "Saved\Logs\BuildTest.log" -Pattern "TestResult=Failed|FinishTest TestResult=Failed"
    ```
    Each match has the test name + the assertion message from the test author. Report those verbatim — they are the structured failure output.

## Traps to avoid

These bit before and the toolbox docs don't all flag them:

- **Non-zero exit from `--test` is the normal way the toolbox reports test failures.** It is *not* a toolbox bug. Read the summary block to know what actually happened.
- **Don't grep the log for `Display:` lines first.** Test outcomes live in `LogAutomationController` lines (`Test Started`, `Test Completed. Result={…}`) and the trailing summary block. Anything else is noise.
- **Don't try to resolve the engine path.** If a build or test fails with "Plugin X failed to load" / "could not find module", that's an engine-selection problem — escalate to the user, do not hunt down DLLs yourself.
- **Don't poll background tasks.** You are notified on completion. Polling reads partial flushes and gives misleading state.
- **Don't time out aggressively.** 5-30 min is normal for a CK editor build. 10 min is the floor; raise it if you've seen this project run longer historically.
- **Angelscript bindings regenerate on editor startup** — and `--test` spins up the editor — so if your C++ change exposed a new API and your AS callsites use it, the test phase exercising the AS path implicitly verifies the AS regeneration too.
- **Do not commit `Saved/Logs/BuildTest.log`** (or the `Build-Editor.log` / `Test-Editor.log` of the separate-logs variant). They're scratch output. The standard `Saved/` is gitignored at the project root, but double-check if you ever stage selectively.

## Gauntlet variant (process-level tests)

Projects that ship a `GauntletTests.json` at the project root (BusterBlock does) can run process-level Gauntlet tests through the same toolbox (v1.12+). Same pre-flight editor-lock check applies — a Gauntlet run boots the project's editor binary in `-game` mode. Compose it single-shot with `--build` so build → gauntlet share one window and one log, same as the default flow above.

```powershell
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --build --config=<Configuration> --target=Editor --gauntlet <TestName|all> --output=Saved/Logs/Gauntlet-Editor.log --project="<session-project-root>"
```

- Drop `--build` to run against the already-built editor.
- `--gauntlet-repeat N` = flake mode; `--gauntlet-include-xfail` = also run expected-FAIL tests;
  `--gauntlet-map /Game/...` = map override.
- `--gauntlet-visual` (v1.16+) = run in a real rendered window (drops `-nullrhi`/`-nosound`, adds
  `-windowed 1280x720`) so a human can watch the test play out. Watchdogs are DISABLED for the
  run (a paused/inspected editor must not be killed) — the run holds the machine-wide build lock
  until it ends, so don't leave a visual run sitting unattended. For human observation, not CI.
  The interactive TUI also has a Gauntlet tab (v1.16+): browse/mark manifest tests, `r` run menu
  incl. a persisted visual-mode toggle.
- Each run's FULL editor log is archived under `Saved/Logs/Gauntlet/<timestamp>/<Test>_rN.log`;
  the `--output` log gets only heartbeats + verdicts + the `=== Gauntlet summary ===` block.
- Verdicts: `PASS`/`FAIL`/`TEST_TIMEOUT` (bridge watchdog)/`AS_COMPILE_HANG`/`EDITOR_STALL`
  (toolbox watchdogs)/`AS_CLASS_MISSING` (exit 4 — AS compile failure)/`HARNESS_MISCONFIG`/`CRASH`
  (NTSTATUS hex)/`INCONCLUSIVE` (exit 0 without the completion line — NOT a pass).
- Budget ~60-90s per test (fresh editor boot each); `all` on BusterBlock is ~25 min.

## Separate-logs variant (two invocations)

Use this **only** when you specifically want the build and test output in separate files — e.g. to grep them independently, or to iterate on tests without rebuilding while keeping the build log around. It runs build and test as two separate invocations, each with its own `--output` and its own pre-flight check:

```powershell
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --build --config=<Configuration> --target=Editor --output=Saved/Logs/Build-Editor.log --project="<session-project-root>"
# then, only if the build succeeded:
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --test --test-pattern <Pattern> --output=Saved/Logs/Test-Editor.log --project="<session-project-root>"
```

**Cost:** this pops **two sequential** progress windows — the test invocation closes the build's window and opens its own, so you never see the whole run in one continuous view. Prefer the single-shot default above unless the separate files earn their keep.

## Arguments

Arguments may combine a config keyword (`dev`/`debug`) and/or a test pattern, in any order — e.g. `/build-test debug Goap`. Missing pieces follow the Phase 1 / Phase 2 resolution rules above.
