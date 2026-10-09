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

## Decide: build path or test-only path

**What changed since the editor last built determines whether you need to close the editor at all.**

- **C++ changed** (`.h`/`.cpp`, `*.Build.cs`, `*.uplugin`, or top-level source layout) → **build path**: single-shot `--build --test`, and the editor **must be closed** (the pre-flight table below enforces this). Building while the editor holds its module DLLs corrupts hot-reload state, and two editors fight over `Saved/`/`Intermediate/`.
- **AngelScript / content only** (`.as`, `.uasset`, config — no C++) → **test-only path**: a standalone `--test` invocation that can run **while your editor stays open**, under the quiescence protocol below. There is nothing to rebuild — the toolbox spawns its own headless editor to run the tests, and (verified) that coexists with your open editor as long as no script/source files change during the run. For *iterative* test runs (running `--test` repeatedly), **pre-warm a resident test editor once** and route runs into it to skip the ~45s per-run boot — see [Warm server](#warm-server-zero-boot-iteration) below.

If you're unsure whether your edits count as "C++ changed," treat it as the build path — a needless rebuild is cheap; skipping a needed one runs tests against stale code.

> **Note on `--config` for the test-only path:** `--config` is a `->needs(--build)` sub-flag, so a standalone `--test` ignores it and runs whatever config is already built (Development by default). That's expected — you're not rebuilding.

## Pre-flight: editor coexistence decision table

The toolbox spawns its own editor. Whether a *different* editor already open on this project is a problem depends on what you're running:

| Invocation | Another editor open? | Action |
|---|---|---|
| any `--build` (incl. `--build --test` / `--build --gauntlet`) | yes | **Wait for it to close** — build + editor DLL/hot-reload contention is real (probe + wait loop below) |
| standalone `--test` | yes | **Proceed with the editor open** — follow the quiescence protocol below |
| standalone single `--gauntlet <Test>` | yes | Proceed under the same protocol (each run is a fresh `-game` boot) |
| `--gauntlet all` | yes | **Prefer waiting** — the ~25 min run makes a mid-run script edit far more likely |
| anything | no | proceed |

Detection is the same in every row — the active editor holds an exclusive write lock on `<session-project-root>/Saved/Logs/<ProjectName>.log` (where `<ProjectName>` matches the `.uproject` filename — e.g. `BusterBlock.log`). Probe it:

```powershell
try { [IO.File]::Open('<session-project-root>/Saved/Logs/<ProjectName>.log', 'Open', 'Write', 'None').Close(); 'free' } catch { 'locked' }
```

**When the table says "wait"** (`'locked'` and you're on a build path): do not kill the process, do not stomp the lock. Use a background loop so the wait is event-driven and you get a completion notification when it's free:

```bash
until ! powershell -NoProfile -Command "try { [IO.File]::Open('<session-project-root>/Saved/Logs/<ProjectName>.log', 'Open', 'Write', 'None').Close(); exit 0 } catch { exit 1 }"; do echo "$(date -u +%H:%M:%S) editor still up, sleeping 60s..."; sleep 60; done
```

Run that in the background with a generous timeout (10+ min). Don't poll yourself — wait for the completion notification, then proceed.

**Caveat:** if YOU are holding the lock from a still-running prior toolbox invocation that you started, the wait will never return — close that toolbox/editor first. The wait pattern is for *other* sessions or stale processes.

### Quiescence protocol (test-only path, editor open)

The one hazard of running `--test` beside your open editor: if any AngelScript/source file changes *during* the run, your live editor hot-reloads and rewrites `Script/Generated/*` mid-run; the toolbox's headless editor can't full-reload, logs `Full Reload is required ... keeping old script code`, and that Error is attributed to whatever test is running → spurious failures/timeouts. The protocol removes that hazard:

1. **Pre-check that the live editor has settled.** Probe the tail of the live log:
   ```powershell
   Select-String -Path "<session-project-root>\Saved\Logs\<ProjectName>.log" -Pattern "==script reload total==|Full Reload is required" | Select-Object -Last 5
   ```
   If the most recent hit is a `Full Reload is required` line (a pending deferred regen), **don't start** — ask the user to focus the editor so the regen completes, then re-probe. If the last line is an old `==script reload total==` with nothing after it, proceed.
2. **Freeze edits for the duration.** From toolbox launch until the completion notification: make **no** edits to `.as` / `.h` / `.cpp` (anything that triggers script regen), and print a user-facing warning in chat:
   > "Running tests beside your open editor — please don't save AngelScript/source edits until it completes (~N min), or the run may report false failures."

   Also caution (there's no cheap way to probe it): if you have the **AutoTests map open and dirty** in your editor, the headless run's populator auto-save can conflict — save or close that map first.
3. **Red-run forensics.** If the run comes back red *and* it ran beside a live editor, before trusting any failure:
   ```powershell
   Select-String -Path "Saved\Logs\Test-Editor.log" -Pattern "Full Reload is required"
   ```
   (Use `BuildTest.log` for the single-shot form.) Any hit → the run is **contaminated, not failed**: re-run the failed subset after the editor is quiescent instead of debugging the failures. Likewise, a *cluster* of settle-timer flakes beside a live editor is machine-contention contamination — same remedy.

> **Toolbox v1.19+** prints its own `LIVE EDITOR DETECTED` advisory, adds a `Contaminated: N` summary line, exits `78` when only contamination remains (no real failures), and auto-retries contaminated tests once — so step 3's manual grep becomes a fallback for older toolbox versions. Exit `77` means a `--build` was refused because an editor is open (pass `--allow-live-editor` to override, or `--no-wait` to fail fast instead of waiting). (Exit `76` is the pre-existing "test boot's own AngelScript failed to compile, ran stale bytecode" code — unrelated to a live editor.)

## Procedure

### Phase 0: Decide whether to run NOW, and how wide

Invoking this skill is not free - a full suite runs from ~10 min to 2.5 h depending on the project
(BusterBlock: 2h 25m at 4691 tests, 2026-10-03; see [Long gates](#long-gates)) and a
`--build --test` adds 5-30 min of editor build. Before running, answer both:

**Is this the right moment?** If you are partway through a planned series of related edits, finish
them first and run **once**. The build cost is per-invocation, not per-edit. Run mid-series only
when a change is novel/risky enough that you want to know immediately, when one change's
correctness gates the design of the next, or when you are actively debugging (there the loop is the
work — scope hard and use the warm server).

**How wide?**

| You are… | Scope |
|---|---|
| iterating on one feature | `--test-pattern <Module>` + warm server (`--test --live`) — seconds per run |
| verifying a finished batch | `--test-pattern` covering **every** module the batch touched |
| claiming done / no regressions / about to commit | full suite, `--test --no-live` — **once**, at the end |

A bare `--test` (no pattern) is the **gate**, not an iteration tool. If you have run it more than
once in a session without the code having changed meaningfully in between, you are burning the
user's time.

**The baseline is the known-red list - do not run a gate just to get one.** When the project's
`AutomationGate.json` has a `knownReds` list (toolbox v1.50+; Ck plugins carry their own from v1.52),
that list IS the baseline: the final gate names any failure that is not on it. A pre-change gate
adds nothing and costs up to hours. If the final gate reports NEW failures, attribute them with the
recipe in [Known reds: new failures, and keeping the list current](#known-reds-new-failures-and-keeping-the-list-current) -
never by re-running the whole suite on a clean tree. Do not run a pre-change gate on the suspicion
that the list is stale, either: a stale list shows itself in the final gate, as a NEW failure that
is still red with your change reverted.

Only when the project has no list (or the toolbox is older, or `--known-reds off`): record the
starting pass/fail counts and the *names* of already-failing tests before your first change, and
diff names, not counts.

**Report the scope you actually ran.** A green `--test-pattern Inventory` is not a green suite; say
which pattern produced the result.

### Phase 1: Confirm config

If the user's request includes a config keyword, use it:

| User says | Flag |
|---|---|
| `dev` / `development` | `--config=Development` |
| `debug` / `debuggame` | `--config=DebugGame` |

Otherwise **omit `--config` entirely** — the toolbox resolves it from its per-project
settings / `Auto` (= the last-built config, read from the newest `Binaries/Win64/*.target`
receipt), which follows whatever the IDE last built.

**Never volunteer an explicit config the user didn't name.** On unique-build-environment
targets every module DLL links a per-config `Default.rc2.res`, so a config FLIP relinks
~all (~1600) module DLLs — and alternating configs between toolbox runs and the user's IDE
causes recurring machine-wide relink storms in BOTH directions. The toolbox's
config-following default (v1.6–v1.8) exists precisely to prevent this; an explicit
`--config` bypasses it.

### Phase 2: Decide what to test

Single-shot needs the test pattern up front (both phases run in one command). Determine it in this order:

1. If the user passed a non-config token (e.g. `/build-test debug Goap`), use it verbatim.
2. Otherwise infer from your own recent edits: look at which Plugins / Source modules you touched. The substring of the module name is enough — `CkGoap` → `Goap`, `CkInventory` → `Inventory`.
3. If you can't infer, ask the user: "Test pattern? (e.g. `Goap`, `Inventory`, or `all`)".
4. For `all`, omit `--test-pattern` entirely so every project test runs — reserve this for the
   end-of-work gate (Phase 0), or when the user asked for it by name.

> **The gate population is declared by the PROJECT, in `AutomationGate.json` at its root (toolbox
> v1.49+).** A test counts as a project test if it is a functional test, if its first dotted segment
> is an enabled plugin/module name, or if it sits under a root the file declares. `Ck` and `Bb` are
> house conventions, not plugins, so without the file `Ck.Snapshot.*`, `Bb.Snapshot.*`,
> `CkAngelscriptGenerator.*` and their siblings are **engine** tests to the toolbox and a bare `--test`
> skips them — on BusterBlock 2026-09-25 that was **2567 of 6206** discovered tests, every save/load
> gate excluded, reported as a healthy green.
>
> **So the `all` gate is a bare `--test`** (plus `--no-live --discover-fresh` for the gate of record).
> No prefix flags to remember: the roots are versioned with the tree.
>
> **Read the `[population]` block every run.** It prints `N of M discovered tests are in the gate
> population`, the roots included and excluded with counts, and — with a pattern — how many the
> pattern selected. If a root that is yours appears under `excluded`, add it to `AutomationGate.json`
> (or pass `--project-prefix <Root>` for one run). `--test --print-population` prints the block and
> exits without running anything — use it before a long gate.
>
> **`--test-pattern` narrows WITHIN the population** (v1.49); it can no longer reach engine tests
> unless you add `--include-engine`. On a toolbox older than v1.49 a pattern *replaced* the population
> (`--test-pattern Ck` substring-matched engine suites), and `--project-prefix` did not exist in
> v1.45-v1.48 — if the toolbox rejects a flag this skill documents, check `UnrealToolbox.exe
> --version` and say what you actually ran instead of improvising a different population.

> **Known reds (toolbox v1.50+).** When `AutomationGate.json` has a `"knownReds"` list, the gate
> passes when every failure is on the list and fails on any **new** failure. Read the
> `=== Known reds ===` block at the end of the summary:
>
> - **`NEW FAILURES`** are the verdict. They are yours to explain (or they came in with the base).
> - **`Still red`** are listed, pre-existing failures. They don't fail the gate.
> - **`Now passing`** means a listed red passed. Remove it with a fresh-boot
>   `--test --no-live --known-reds prune` and commit the file.
> - **`Flaked`** means a listed flaky test failed, then passed when re-run alone.
>
> **Never add an entry to make your own change's red go away.** An entry needs `test` (the full
> dotted path), `status` (`red` or `flaky`), `reason`, `evidence` and `added`. It goes in its own
> commit and is reviewed. With a current list you don't need a pre-change baseline run: a new
> failure is named for you.
>
> `--known-reds off` gives the raw verdict. Exit 80 now also means a listed test no longer exists:
> it was renamed or deleted, so fix the entry in the same change.
>
> **Plugin lists (toolbox v1.52+).** A plugin can carry the known reds for its own tests in an
> `AutomationGate.json` beside its `.uplugin` (only `"knownReds"`, never `"roots"`). Every project
> that contains the plugin reads it, so the plugin's tests are judged alike everywhere. Its result
> lines end in `[Plugins/<Name>]`.
>
> - **A plugin's entries are changed in the plugin's repo, by PR** - never from the host. Prune
>   never edits them; a plugin's `Now passing` red says "open a PR there".
> - **A test listed in two files exits 80** and names both. When a plugin list starts covering a
>   test the host file lists, drop it from the host file in the same change that bumps the plugin.
> - A plugin entry naming a test that no longer exists exits 80. A plugin the project does not
>   enable has its list skipped, and the run says so.
> - A listed `flaky` that passes is reported (`Listed flaky, passed`); remove the entry by hand once
>   its cause is fixed.
>
> An older toolbox ignores plugin files and judges those tests raw.
>
> **Every run names its failures** (`Failed tests (N):`), and **a run that did not produce a result
> for every requested test exits 1** with `RUN INCOMPLETE` and the missing names. Before v1.50 such
> a run could exit 0. Usually it is a stale test cache, so try `--discover-fresh`.

> **Deferred tests (toolbox v1.56+).** `AutomationGate.json` can list tests that stay in the gate
> population but are left out of a plain `--test`: `"deferred": [ { "pattern": "Benchmark",
> "reason": "...", "added": "YYYY-MM-DD" } ]`. It is for tests that cost time without saying
> whether a change is safe to merge (benchmarks, stress runs, a listed red that runs to its timeout).
>
> - **A plain `--test` is the merge gate and skips them; `--include-deferred` is the scheduled gate
>   and runs everything.** The first `[population]` line says how many are deferred, and the
>   `deferred:` line lists each pattern with its count. Say which of the two you ran.
> - A pattern is a lane pattern, like `--serial-lane`: `Benchmark` is a whole dotted segment,
>   `*Perf` ends a segment, tokens joined by `.` must all match. A full test path also defers
>   anything nested under it, so **read the per-pattern count after adding one**.
> - `--test-pattern` does not reach a deferred test. The run says `N more match but are deferred`;
>   add `--include-deferred` to run it.
> - A deferred listed red is never `Now passing` in a merge gate; only a run with
>   `--include-deferred` can prune it.
> - **Exit `80`** if the list does not describe the build: a pattern that matches no test, a pattern
>   made only of `*`, or patterns that defer every test under a declared root (drop the root).
> - Never add a pattern to make a failing or slow test of your own change go away. An entry needs a
>   reason a reviewer would accept for keeping the test out of every merge.
> - A toolbox older than v1.56 refuses a file that has the key (exit 80), so the CkAuto pin with
>   v1.56 lands in a project before its list does.

> **Renderer-only tests (toolbox v1.51+).** A test flagged `NonNullRHI` needs a real renderer, and a
> headless (`-nullrhi`) editor does not list it at all. The toolbox discovers in both modes and runs
> those tests in **one extra real-renderer editor (off-screen)**. With several editors (v1.55+) that
> is one more group, `[renderer]`, picked up by the first editor that runs out of lanes while the
> others are still going; on one editor, and after `--build`, it still runs after the headless lanes.
> The population block reports them as `renderer-only: N`, and the summary ends with
> `Renderer-only: N test(s) ran in a real-renderer editor`.
>
> - **Flag a test `NonNullRHI` when it genuinely needs rendering:** layout capture, render targets,
>   real Slate windows, shader compiles. **Never** use `if (!FApp::CanEverRender()) { AddInfo("Skipped"); return true; }`.
>   That passes green in every headless gate while testing nothing.
> - **Exit `81`** means the renderer-only tests were not run. Either the real-renderer editor could not
>   come up (for example, no GPU) or the list could not be discovered. That is not a gate verdict. On a
>   machine that cannot render, pass `--skip-renderer-tests`. The run then names what it skipped and
>   keeps its normal verdict. A selection that is *only* renderer-only tests, when waived, exits 1
>   (nothing ran).
> - With `--no-nullrhi`, renderer-only tests simply run in the main run.
> - The first `--test` after the toolbox upgrade re-discovers once (two boots), to learn the
>   renderer-only list.
> - **A headless-green test that goes red only in the full suite** after tests moved to the renderer
>   pass is a lane-order leak (its predecessors changed), not a renderer need: run it alone
>   (`--test-pattern <exact path>`) before flagging it.

**The matcher is forgiving**: case-insensitive substring tokens, any order. `Goap`, `cktests.GOAP`, and `goap.basicplan` all work. You don't need the full dotted test path.

### Phase 3: Build + test (single-shot)

**First consult the Pre-flight decision table** (see above) — once, before this invocation. The single-shot `--build --test` is a build path, so it needs the editor closed; for an AS/content-only change prefer the standalone `--test` (Separate-logs variant) which can run with the editor open.

Run in the **background** — a CK-family editor build is 5-30 minutes. Use a 600000 ms (10 min) timeout, then await the completion notification. **Do not poll the log.**

The project root is the **primary working directory of the current session** — whatever repo Claude Code was launched from. However, if the changed files live in a *different* project (e.g. work was done in a sibling repo like BusterBlock while the session root is CkPlugins), build that project instead. Always `Set-Location` to the project being built explicitly before invoking the toolbox so the relative `./CkAuto/` and `--project=` paths resolve correctly.

```powershell
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --build --target=Editor --test --test-pattern <Pattern> --output=Saved/Logs/BuildTest.log --project="<session-project-root>"
```

(Drop `--test-pattern` for the `all` case. Add `--config=<Configuration>` ONLY when the user
named a config in Phase 1.) The test phase only runs if the build succeeded.

**Do NOT** pass `--generate` for normal iteration — it forces a project-files regeneration that adds time for no benefit. Use it only when a `*.Build.cs`, `*.uplugin`, or top-level source layout has changed since the previous build.

One progress LogViewer window opens at build start and is reused through the test phase (toolbox v1.15+), so the user watches build → editor boot → tests in a single window. Nothing to launch or wire — it's default-on whenever `--output` is set. As of toolbox v1.40, it spawns **minimized to the taskbar with a brief flash** and does not take focus — the run no longer yanks the user's foreground window away mid-task. Per-run override: `--progress-window <focus|background|minimized|minimized-flash>`; the persistent preference lives in the toolbox's per-project `settings.json` (`progressWindow.mode`). On a true-headless / no-desktop machine (CI), add `--no-progress-window`.

As of toolbox v1.46 / LogViewer v1.7, the `--output` log also carries `##ftx[progress …]` marker lines that drive that window's per-stage progress strip, taskbar-button progress and title. They are written to the file only — stdout is unchanged — and are machine lines: skip them when reading the log. None of the grep patterns below match them, and the `=== Test summary ===` block still comes after the last test marker (exception: a failed `--build` in a combined run ends with a `tests st=skip` marker).

Agent guidance: don't pass `--progress-window` by default — the persisted setting/default already governs. Pass it only when the user explicitly asks to watch the run, and then prefer `background` or `focus`.

**And do not pass `--no-progress-window` on a machine with a desktop.** The minimized window is how the user sees how far a build or gate has got; an agent that hides it leaves them asking. This holds for every build, test and gauntlet run, including many short runs in a row and a gate you launch detached (hide the toolbox's console if you like; keep the window). Suppress it only on a true headless / CI machine, or for a sub-minute utility call that builds and tests nothing (`--version`, `--print-population`, `--build-status`). To show a run that was started hidden: `CkAuto/LogViewer.exe --follow "<the --output file>"`.

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

## Known reds: new failures, and keeping the list current

### The gate reports NEW FAILURES - attribute them, do not re-baseline

1. **Run each NEW test alone**: fresh boot, one lane, list off -
   `--test --no-live --parallel 1 --known-reds off --test-pattern "<full test path>"`. Read the verdict
   from that run's own `Failed tests (N):` block (a pattern can also select sibling tests).
2. **Green alone** -> it fails only in the suite. That is NOT yet "not mine": a change that leaks
   shared state (an untracked entity, a console variable, a registry entry, a file on disk) reds a
   LATER test only in-suite. If your change touches anything shared, re-run that test's group (a
   `--test-pattern` covering it and the tests that ran before it in its lane) with and without your
   change before calling it load-sensitive. Only then does it qualify as `flaky` (red in a full
   gate, green alone).
3. **Red alone** -> prove whose it is before touching the list: revert only your change (or move the
   submodule you bumped back to its previous pin), rebuild, and run just those tests alone again.
   Red there too = pre-existing; green there = you caused it, fix it.
4. A test that passes alone on one run and fails alone on another **oscillates**: list it `red`, not
   `flaky` (as flaky, a failing solo re-run fails the gate; as red, a pass only reports `Now passing`).
   Start its `reason` with `OSCILLATES` and record a follow-up to fix the test. **While it is listed,
   that test detects nothing** - a real regression in it reads as "still red". It is a debt, not a
   classification to be comfortable with.
5. A listed `flaky` that failed is re-run alone by the gate itself - unless the run is incomplete or
   has other NEW failures. Then do that re-run by hand before judging.

Never add an entry to make your own red go away, and never run the whole suite on a clean tree to
find out what was already red: steps 1-3 answer that for the handful of tests that matter.

### Where an entry belongs

- A test of the **project's own** -> the project's root `AutomationGate.json`.
- A **plugin's** test that is also red in the plugin's home project -> that plugin's
  `AutomationGate.json`, by PR in the plugin's repo. Never copy it into a host file: a test in two
  files exits 80.
- A plugin's test that is red **only in this project** -> the project's root file, with the reason
  starting `HOST-COUPLED:` and naming the coupling.

### Keeping the list current is a standing job, not a one-off

A list is only a baseline while it matches the branch. Left alone it goes stale in days (BusterBlock's
gained 19 unlisted reds in the week nobody ran a full gate), and then every agent is back to proving
which reds are theirs.

- **A full judged gate on the main branch needs to run on a schedule, with a named owner** - that is
  what keeps the list honest. On a machine that cannot render, add `--skip-renderer-tests` and say so.
  **Until a project has that scheduled gate**, its list is only as fresh as the newest `evidence` date
  in it, and staleness is found the slow way: a NEW failure in someone's final gate that is still red
  with their change reverted. That person lists it (own commit, `reason` + `evidence`) - the cost of
  having no schedule lands on whoever gates next.
- **NEW failures on a clean main branch** are either a regression someone merged (find the commit,
  fix or revert) or a pre-existing red nobody listed (attribute it as above, then list it in its own
  commit with `reason` and `evidence`).
- **`Now passing`** -> remove the entry (`--known-reds prune` on a fresh-boot full run you were
  running anyway, or by hand), commit the file. For a plugin's entry, open the PR in the plugin's
  repo. **Exception: an entry whose `reason` starts `OSCILLATES` is NOT removed on one pass** - it
  passes some of the time by definition, and pruning it only brings it back as NEW in the next gate.
  Remove it when the test is fixed. (`prune` does not know this: check its removals, restore any
  oscillator.)
- **`Listed flaky, passed`** proves nothing by itself; remove a `flaky` entry only when its cause is
  fixed.
- **Seeding a list from nothing** (a new project): two full gates on one build with `--known-reds off`,
  then every failure alone. `red` = red in both gates AND red alone; `flaky` = red in at least one
  gate, green alone. Each entry needs `test`, `status`, `reason` (the failure text), `evidence`
  (which gates, which commits, which toolbox) and `added`.
- **After a submodule bump that moves an entry into a plugin's list**, drop it from the host file in
  the same change.

## Long gates

- **A full gate can outlast an agent's background-command limit** (2 h in Claude Code; BusterBlock's
  gate is ~2.5 h). Launch it as a detached process, keep its PID, and wait on the process exiting;
  killing the waiter must not kill the gate. Without an exit code, read the `=== Test summary ===`
  and `=== Known reds` blocks and look for `RUN INCOMPLETE`.
- **The multi-PIE tests** (`.Net.` and the snapshot suites) run one editor at a time (two would
  collide on localhost ports). From v1.55 they are ONE group in one editor, beside the other lanes;
  before that they ran 12 per editor and each batch paid an editor boot (on BusterBlock about 80 min
  of a 2 h 20 min gate). If that editor hangs it costs one watchdog timeout and the group resumes in a
  fresh editor. `--net-batch-size N` puts a cap back for one run, to find where a hang starts.
- **`=== Fill pass ===` (v1.55+)**: tests an editor left behind after giving up on its group (two
  boots with no result) are run once more at the end of the run. The run is whole if they get results
  then; `RUN INCOMPLETE` is what is still missing after that.
- **Test editors read the machine's saved game settings** unless told otherwise. A saved frame-rate
  limit applies to every test editor, and a test that changes a setting changes it in your game.
  `--own-game-settings` (v1.55+, opt-in) gives each test editor an empty settings file of its own
  under `Saved/UnrealToolbox/TestGameSettings/`. `--editor-args "<args>"` adds editor arguments to
  every test editor (a diagnostic, for example a CPU trace of a headless editor).
- **A headless command no longer needs a saved engine choice (v1.55+).** `--build`, `--test`,
  `--gauntlet` and `--warm-server` fall back to the engine the `.uproject` names and print a NOTE;
  `--engine-path <dir>` names the engine folder outright on a machine with no registered engine.
- **`RUN INCOMPLETE` after a boot hang**: a lane editor that stalls during boot is killed by the idle
  watchdog; two hung spawns abandon the group. Do not re-run the whole gate. Take the group's tests
  from its `Automation RunTests a+b+c` line in the log and run them as targeted judged runs
  (`--test-pattern` takes one AND-pattern per run), then re-run any failed listed flakies alone.
- **Copy a gate's `--output` log somewhere else before the next run**: the toolbox rotates
  `Saved/Logs`.
- **Never run two gates on one machine at once** unless you mean to: the second one starves the
  first, and load-sensitive tests go red.

## Traps to avoid

These bit before and the toolbox docs don't all flag them:

- **Non-zero exit from `--test` is the normal way the toolbox reports test failures.** It is *not* a toolbox bug. Read the summary block to know what actually happened.
- **Don't grep the log for `Display:` lines first.** Test outcomes live in `LogAutomationController` lines (`Test Started`, `Test Completed. Result={…}`) and the trailing summary block. Anything else is noise.
- **Don't try to resolve the engine path.** If a build or test fails with "Plugin X failed to load" / "could not find module", that's an engine-selection problem — escalate to the user, do not hunt down DLLs yourself.
- **Don't poll background tasks.** You are notified on completion. Polling reads partial flushes and gives misleading state.
- **Don't time out aggressively.** 5-30 min is normal for a CK editor build. 10 min is the floor; raise it if you've seen this project run longer historically.
- **Angelscript bindings regenerate on editor startup** — and `--test` spins up the editor — so if your C++ change exposed a new API and your AS callsites use it, the test phase exercising the AS path implicitly verifies the AS regeneration too.
- **Do not commit `Saved/Logs/BuildTest.log`** (or the `Build-Editor.log` / `Test-Editor.log` of the separate-logs variant). They're scratch output. The standard `Saved/` is gitignored at the project root, but double-check if you ever stage selectively.
- **Don't edit AngelScript/source during a test-only run beside a live editor.** A saved `.as` edit makes the live editor rewrite `Script/Generated/*` mid-run and the headless test editor logs `Full Reload is required` — grep for that phrase before trusting a red run (see the Quiescence protocol). Freeze edits until the completion notification.
- **Exit `80` means the gate population was refused — no verdict was produced.** `AutomationGate.json` is present but broken (bad JSON, unknown key), or a declared root (file or `--project-prefix`) matches no discovered test. The `[population] ERROR:` line names it. Fix the file or the root name; try `--discover-fresh` if the root is new. After `--build`, where the test list is re-read mid-run, the tests still run and the exit becomes 80 at the end. It is not a build failure even though the summary block may be missing. Since v1.50 exit 80 also covers a `knownReds` entry naming a test that no longer exists (`[known-reds] ERROR:` names it; fix the entry, or `--known-reds prune` removes it), and a broken `knownReds` list (missing `reason`/`evidence`/`added`, bad `status`, a duplicate).
- **Exit `77`/`78`/`79` are not test failures.** `77` = a `--build` was refused because an editor is open; `78` = the run was inconclusive because a live editor contaminated it (`Contaminated: N` in the summary), with no genuine failures; `79` = a `--build` was refused because an explicit `--config` would FLIP the build config (omit `--config`, or pass `--allow-config-flip` to accept the relink). None means a real test failed. (`76` is the older "AngelScript failed to compile in the test boot itself" code — also not a test failure.) **Note `79`, not 77, for the config flip:** it was authored as 77 on `dev` while 77/78 were already taken on the live-bridge branch, and moved on merge — if you see an older doc or binary citing 77 for a config flip, it predates v1.35.
- **Exit `75` means the engine is busy, not that anything failed — and since v1.42 it is rare.** The engine lock is reader/writer. `--test`, `--gauntlet`, and warm-server boots hold it **shared** (they only read engine binaries), and since v1.42 a **build does too**, as long as the target uses a Unique build environment — such a target compiles every module, engine ones included, into its own project's `Binaries/`, so it cannot touch what another project's editor has mapped. Net effect: **a test and a build in two different worktrees sharing one engine now run at the same time, in either order.** What still serializes: anything on the **same project** (a second test, or a build vs a test — two editors on one worktree would race `Saved/`, the AS bytecode cache, and populator map saves); **build vs build** anywhere on that engine (they share the C# UBT/UAT assemblies); and anything involving **cook/package**, which stay fully exclusive. A Shared-build-environment target also stays fully exclusive, because it links against `Engine/Binaries` and can rewrite what another project's editor maps. `--build-status` lists every live holder by session; `--no-wait` converts a wait into exit 75. Both sides must be on v1.42+ for the build/test concurrency — an older vendored `UnrealToolbox.exe` still over-serializes (and misreports live holders as STALE), so redeploy it in every worktree. **Since v1.57, build vs build on different worktrees runs in parallel too**, because UnrealBuildTool in this engine fork arbitrates engine writes itself with a reader/writer lock: a build that will write under `Engine/` (a stale engine rules assembly after a UBT change, a ShaderCompileWorker relink after an engine change, a Shared-environment target, `-Rebuild`, live coding) upgrades to exclusive and the others wait on it, with the holder named in the wait line; a build whose outputs all land under its own project never blocks another. IDE builds obey the same gate. Every `--build` prints one `=== Build lock: SHARED|EXCLUSIVE (...) ===` line; `--serialize-builds` (or `UNREAL_TOOLBOX_SERIALIZE_BUILDS=1`) forces the old exclusive hold, and the engine-side kill switch is `UnrealBuildTool_BuildConfiguration__bExclusiveEngineBuildLock=true` in the environment (or `<bExclusiveEngineBuildLock>true</bExclusiveEngineBuildLock>` under `BuildConfiguration` in `BuildConfiguration.xml`). Same-project build vs build (toolbox or IDE) is still exclusive, by a per-project lock inside UBT.

## Gauntlet variant (process-level tests)

Projects that ship a `GauntletTests.json` at the project root (BusterBlock does) can run process-level Gauntlet tests through the same toolbox (v1.12+). The Pre-flight decision table applies — a single `--gauntlet <Test>` boots the project's editor binary in `-game` mode and can run with your editor open (quiescence protocol), but `--build --gauntlet` needs the editor closed and `--gauntlet all` prefers waiting (its ~25 min run widens the mid-run-edit window). Compose it single-shot with `--build` so build → gauntlet share one window and one log, same as the default flow above.

```powershell
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --build --config=<Configuration> --target=Editor --gauntlet <TestName|all> --output=Saved/Logs/Gauntlet-Editor.log --project="<session-project-root>"
```

- Drop `--build` to run against the already-built editor.
- `--gauntlet-repeat N` = flake mode; `--gauntlet-include-xfail` = also run expected-FAIL tests;
  `--gauntlet-map /Game/...` = map override.
- `--gauntlet-visual` (v1.16+) = run in a real rendered window (drops `-nullrhi`/`-nosound`, adds
  `-windowed 1280x720`) so a human can watch the test play out. Watchdogs are DISABLED for the
  run (a paused/inspected editor must not be killed) — the run holds the engine lock (shared, so
  other worktrees' tests still run, but any build on that engine waits) until it ends, so don't
  leave a visual run sitting unattended. For human observation, not CI.
  The interactive TUI also has a Gauntlet tab (v1.16+): browse/mark manifest tests, `r` run menu
  incl. a persisted visual-mode toggle.
- Each run's FULL editor log is archived under `Saved/Logs/Gauntlet/<timestamp>/<Test>_rN.log`;
  the `--output` log gets only heartbeats + verdicts + the `=== Gauntlet summary ===` block.
- Verdicts: `PASS`/`FAIL`/`TEST_TIMEOUT` (bridge watchdog)/`AS_COMPILE_HANG`/`EDITOR_STALL`
  (toolbox watchdogs)/`AS_CLASS_MISSING` (exit 4 — AS compile failure)/`HARNESS_MISCONFIG`/`CRASH`
  (NTSTATUS hex)/`INCONCLUSIVE` (exit 0 without the completion line — NOT a pass).
- Budget ~60-90s per test (fresh editor boot each); `all` on BusterBlock is ~25 min.

## Separate-logs variant (two invocations)

Use this when you specifically want the build and test output in separate files — e.g. to grep them independently, or to iterate on tests without rebuilding while keeping the build log around. **This is also the form the test-only path uses** — the standalone `--test` invocation below is exactly what you run (editor open, under the quiescence protocol) for an AS/content-only change. It runs build and test as two separate invocations, each with its own `--output` and its own pre-flight decision:

```powershell
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --build --config=<Configuration> --target=Editor --output=Saved/Logs/Build-Editor.log --project="<session-project-root>"
# then, only if the build succeeded:
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --test --test-pattern <Pattern> --output=Saved/Logs/Test-Editor.log --project="<session-project-root>"
```

Do **not** hardcode `--parallel` here — the toolbox sizes the lane count to the machine it is on. See [Parallel lanes](#parallel-lanes-full-suite-runs).

**Cost:** this cycles through **two sequential** progress windows — the test invocation closes the build's window and opens its own — so you never see the whole run in one continuous view (both windows now spawn minimized+flash by default, so the churn is taskbar-level rather than on-screen). Prefer the single-shot default above unless the separate files earn their keep.

## Parallel lanes (full-suite runs)

**Toolbox v1.39+ sizes this itself — you should not normally pass `--parallel` at all.** Test batches are
spread over N concurrent headless editors, where N is derived from the machine: the lower of
`(physicalCores + 2) / 3` and `(availableRAM - 4GB) / 6GB`, capped at 4. Tests matching a serial lane
(`Net`, `*Snapshot*`) stay pinned to one editor chain regardless, so multi-PIE suites never overlap.
When a run has such a chain (v1.55+), the other tests are cut into twice as many lanes as there are
editors, so an editor that finishes early keeps pulling work; the summary counts lanes, not editors
(`6 lane(s)` on 3 editors).
An auto-sized run says so in its first lines:

```
[utb --test] auto-sized to 3 concurrent editor(s) from 8 physical core(s) / 38 GB free (~6 GB per editor).
```

**Why it is derived rather than a fixed number.** This skill is vendored to every developer, and a CLI
`--parallel` **overrides** the per-machine `tests.maxParallel` setting — so hardcoding a width here would
strip the escape hatch from exactly the underpowered machine that needs it. Each editor holds ~5.7 GB
resident (measured), so three of them is ~17 GB: fine on a 64 GB desktop, thrashing on a 16 GB laptop.
Precedence is `--parallel N` (this run) > persisted `tests.maxParallel >= 1` (this machine) > auto.

**Measured on BusterBlock 2026-07-30**, same 1324-test suite, same binary, back to back on an 8-core /
63 GB machine — this is what auto is calibrated against, *not* what every machine will see:

| Run | Wall clock | Speedup |
|---|---|---|
| serial | 23m 0s | — |
| 3 lanes (what auto picks here) | **9m 39s** | **2.4x** |
| 4 lanes | 8m 52s | 2.6x |

A 4th lane bought only ~8% more, which is why auto caps at 4 and prefers 3 on this class of machine.
Pass `--parallel N` yourself only to pin a run for measurement, or to force serial with `--parallel 1`.

**Verdict fidelity was checked, not assumed.** All three runs reported the identical 1324 / 1319 passed /
5 failed / 0 contaminated, with the same four stable failures. Each run also had exactly **one** extra
failure, a *different* test every time — **including the serial run** — i.e. pre-existing flakiness, not
something parallelism introduced. One test that failed serially actually *passed* under parallel; broken
isolation would push reds in one direction only.

**Two things this was NOT measured against — do not assume them:**
- **`--build --test`.** Only standalone `--test` was benchmarked. After a build, `Script/Generated/*` may
  need regenerating, and under parallel only ONE editor wins `[RegenOwnership]` — the others log
  `runs as SECONDARY`, which disables generator writes and AS self-heal for them. Nothing makes a
  SECONDARY *wait* for the owner to finish writing, so a build that actually changes codegen is an
  untested race. Keep the single-shot `--build --test` serial until someone measures it.
- **Small runs.** Each lane pays its own ~45-60s editor boot. Below a few hundred tests that dominates.

**Lanes and the live/warm path are mutually exclusive**, because the live path hands the whole list to ONE
serving editor. On toolbox ≤v1.37 that combination dropped `--parallel` **silently** — with a warm server
up, `--test --parallel 6` ran fully serially and said nothing. From v1.38+ the two resolve by *who asked*:

| You ran | With a warm server serving |
|---|---|
| `--test` (auto-sized width) | **routes into the warm server**, zero boot — a derived width never vetoes it |
| `--test --parallel N` (explicit) | **declines** the warm server and takes the lanes, saying so |
| `--test --live --parallel N` | routes live and **warns** that `--parallel` is ignored |

So the zero-boot iteration loop below still works untouched — you only lose it by naming a width yourself.
For a full-suite gate, `--no-live` is the reliable way to guarantee lanes regardless of what is serving.

## Warm server (zero-boot iteration)

**Toolbox v1.20+.** Every `--test` normally boots a fresh headless editor (~45s) and tears it down. When you're iterating — running the test-only path repeatedly on the same AS/content — you can pay that boot **once** by keeping a resident **warm server**: a headless `-CkTestBridgeServe` editor that serves test runs over a file-drop bridge (the CkTestsBridge module). It coexists with your own open editor (headless, `-nullrhi`, and it declines AngelScript-regen ownership so your editor stays primary for codegen).

**Pre-warm the moment you start writing tests**, so the boot overlaps your edit time.

**Decide whether to show the window — do NOT reflexively suppress it.** v1.22 exists *specifically* so an
interactive user can see the warm server booting and running: v1.21 had made it windowless and the
result was that a user had **no indication it existed or was booting**. So the LogViewer is a feature,
not desktop noise. As of v1.40 it also spawns minimized+flash by default rather than fronting on
screen, so the cost of leaving it on is much lower than the table below originally assumed — a window
that never covers anything is a cheaper default to leave visible:

| Situation | Pass `--no-progress-window`? |
|---|---|
| True headless / CI / no interactive desktop | **yes** — there is nothing to show it on |
| Firing many short runs in a row | **no** by default - a minimized+flash window per run is quiet enough; suppress only when the user has said the flashes bother them |
| A long operation the user is waiting on (a cold pre-warm, a full suite) | **no** — the window is how they know it's alive |
| The user asked to watch, or asked "is it doing anything?" | **no**, obviously |

When in doubt with the user present, leave it visible: the taskbar flash IS the liveness signal now,
so an unexplained 50s silence is still worse than a quiet minimized window. If the user actually wants
to watch the run (not just know it's alive), use `--progress-window background` or `--progress-window
focus` rather than relying on the default. (Earlier wording here said an agent should *always*
suppress it. That flattened the v1.22 changelog's own rule — "CI/agents get no window; interactive
humans get the one window" — into a blanket, and the result was users seeing nothing during
multi-minute operations.)

```powershell
# headless / CI ONLY (no desktop to show a window on):
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --warm-server start --no-progress-window --project="<session-project-root>"
# user is present and waiting on the boot — let them see it:
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --warm-server start --project="<session-project-root>"
```

`start` is **idempotent** (a no-op if one is already serving) and blocks until the server arms (~60s cold) or times out. Then route runs into it with `--live` — no boot:

```powershell
# a routed run REUSES the warm server's window; add --no-progress-window only on headless / CI
Set-Location "<session-project-root>"; ./CkAuto/UnrealToolbox.exe --test --live --test-pattern <Pattern> --output=Saved/Logs/Test-Editor.log --project="<session-project-root>"
```

- **`--live`** routes into the warm server (or *launches* one if none is serving, then routes — falling back to a fresh boot only if it can't come up). `--no-live` forces today's fresh-boot path.
- **`--warm-server status`** prints the serving pid / idle-or-busy (exit 0 serving, 1 none); **`--warm-server stop`** terminates an idle server. The server also self-quits after ~15 min idle or a ~2 h wall-clock cap, so a forgotten one cleans itself up.
- **Window (v1.22+):** run *without* `--no-progress-window` and `--warm-server start` opens ONE LogViewer for the server's whole life — boot → idle → the test progress of routed `--live` runs (they execute inside it) → idle — closed by `--warm-server stop`. A live run reuses that window rather than popping a second. **This window is the point of v1.22, not a side effect** — v1.21 had made the warm server windowless and left an interactive user with no sign it existed. Suppress it for headless/CI and rapid-fire short runs; leave it visible when a human is waiting on a long operation. See the decision table above.
- **Fidelity:** live/warm results are for **iteration**; a **fresh boot** (`--no-live`, or the clean `--build --test` build path) stays the **gate of record** for any "done" / "no regressions" claim. Re-run `--no-live` before reporting. *Measured 2026-07-25, so you know what this caveat is and isn't:* a full 1271-test suite through a warm server showed **no state accumulation** (throughput tracked test weight, not elapsed time) and **full verdict parity** with fresh boots (13 deterministic failures reproduced identically, 10-of-10 by name on the largest cluster). So the rule is about process freshness as a matter of principle — not a known divergence.
- **`--build` handles the warm server for you (v1.25+).** It stops a warm server *this toolbox launched* before building, then proceeds. You do **not** need to `--warm-server stop` first. Ownership is checked against a launch sentinel (`pid` + process creation time since v1.34), so a server the toolbox does **not** own — in particular the user's own interactive editor — is never terminated; `--build` waits for that one instead.

### Borrowing the USER's editor (`--live` into an interactive session)

`--live` can route into the user's own open editor, not just a warm server — but only if **they opted in**, and it is **off by default**. Know the cost before you invoke it:

- **Opt-in:** Editor Preferences → Ck → **Ck Test Bridge → ServeMode**. `Off` (default) = that editor never serves. `Allow` = it may be borrowed. Persisted per-user, never committed.
- **A plain `--test` (Auto) DECLINES an interactive editor** and fresh-boots, printing *"Not routing into that editor…"*. That is deliberate, not a bug — borrowing someone's session is an explicit act, so it requires `--live`.
- ⚠ **It replaces their open level and does not restore it.** Automation loads a map per test, so when the run ends they are left on the last test map and must reopen their own level. **Say so before you do it.** Their *work* is never at risk — a dirty world makes the run refuse outright (`dirtyWorld`) — what they lose is their place.
- PIE runs visibly in their window during the suite, and the window title shows `[CkTestBridge: SERVING]` / `RUNNING TESTS`.
- Focus does **not** matter (measured: 49s focused vs 52s unfocused vs 2m00s fresh-booted, same 37 tests). Any older note saying the editor must be foregrounded is wrong — that was a misdiagnosis of the toolbox's own poll cadence.
- **Prefer a warm server.** It dominates on every axis except RAM: no map hijack, no PIE in their window, no focus questions.

## Arguments

Arguments may combine a config keyword (`dev`/`debug`) and/or a test pattern, in any order — e.g. `/build-test debug Goap`. Missing pieces follow the Phase 1 / Phase 2 resolution rules above.
