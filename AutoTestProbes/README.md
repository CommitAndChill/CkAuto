# AutoTest populator integration probes

End-to-end regression / demonstration tests for the **CkTests AutoTest map populator**
(`Plugins/CkTests/Source/CkTestsEditor/Private/CkAutoTestMapPopulator.cpp`).
Per-strategy unit tests cover the populator's individual code paths; the
probes here cover the **observable end-to-end behavior** that unit tests
can't see — specifically, that the populator's OFPA-aware save path leaves
the target `.umap` byte-identical on disk after a routine test add.

This suite is **project-agnostic**. All values are discovered at runtime (or
passed as parameters); the same scripts run unmodified against any Ck
project that consumes both the `CkAuto` and `CkTests` submodules. Expected
install location is `CkAuto/AutoTestProbes/` at the project root, so project
root is `$PSScriptRoot/../..` from every script.

## Suite

| Probe | Flow | What it exercises |
|---|---|---|
| `_probe_lock_tolerance.{bat,_restore.bat}` | Mid-session, AS file-watcher drain | Drops a UCk_AutoTest_Base subclass with a timestamped class name, waits for the populator's post-AS-compile sync, verifies the target `.umap` SHA-256 + LastWriteTime are unchanged on disk and exactly one new external `.uasset` appeared. Demonstrates the "teammate can hold an LFS lock on this `.umap` and I can still add tests" promise. |

## Running — lock_tolerance

Editor MUST be running before invoking. The probe refuses if it can't find a
write-locked `<Project>*.log`.

```cmd
:: REQUIRED: -MapPath points at the .umap whose populator config you want to verify.
:: OPTIONAL: -TestSourceDir picks where the probe .as is dropped (default <ProjectRoot>/Script/).

:: Example — BusterBlock-side AutoTests map:
CkAuto\AutoTestProbes\_probe_lock_tolerance.bat ^
    -MapPath Content/BusterBlock/Map/AutoTests/AutoTests_BB_MAP.umap

:: Example — CkTests-side AutoTests level (probe .as must be in CkTests's scope):
CkAuto\AutoTestProbes\_probe_lock_tolerance.bat ^
    -MapPath Plugins/CkTests/Content/AutoTests/AutoTests_CkTests_Level.umap ^
    -TestSourceDir Plugins/CkTests/Script

:: Wait ~5-10s for the populator to settle. Watch the editor's Output Log
:: (filter to 'cktestseditor') for the "1 spawned, ... Auto-saved." line.

:: Verify:
pwsh CkAuto\AutoTestProbes\_probe_verify.ps1

:: Clean up the dropped probe .as + sidecar:
CkAuto\AutoTestProbes\_probe_lock_tolerance_restore.bat
```

### Verifier exit codes

- `0` — PASS (`.umap` byte-identical on disk + 1 new external `.uasset`).
- `1` — FAIL (`.umap` was touched, or no external created).
- `2` — Usage error (no sidecar, etc).

### Expected PASS output

```
Lock-Tolerance Probe Verifier
=============================

  Target map:        Content/BusterBlock/Map/AutoTests/AutoTests_BB_MAP.umap
  Probe class:       UCk_AutoTestProbeLockTolerance260514142055
  Sidecar:           D:\Repos\BusterBlock\Saved\AutoTestProbes\lock_tolerance.json

State comparison (pre -> post):
  SHA-256:           3FD8...F2B59
                  -> 3FD8...F2B59
  Size:              9012 bytes -> 9012 bytes
  LastWriteTime:     2026-05-14 14:18:52
                  -> 2026-05-14 14:18:52
  IsReadOnly:        True -> True       <-- file can be locked the whole time!
  Externals count:   68 -> 69

git status (target paths):
  A  Content/__ExternalActors__/.../<NewGuid>.uasset

Populator log scan:
  Found populator 'spawned' line in latest log — populator ran during this session.

Verdict:
  [PASS] .umap SHA-256 unchanged — file is byte-identical on disk.
  [PASS] .umap LastWriteTime unchanged — OS confirms no write occurred.
  [PASS] External-actor count grew by exactly 1 (68 -> 69).

VERIFICATION: PASS
```

The headline claim: **`.umap` SHA-256 is bit-for-bit identical before and after
a populator-driven test add.** That's mathematically unforgeable — same hash
means same bytes means the file was not rewritten.

## Runtime discovery

Probes resolve everything from on-disk state or required parameters:

- **Project root + name**: walk up two levels from script location, find the
  `.uproject`, use its stem.
- **Editor-running check**: any `<ProjectName>*.log` in `Saved/Logs/` being
  exclusively write-locked = editor up. Works regardless of process-name
  renames and covers `-ABSLOG=<custom>.log` launches.
- **Externals directory**: derived from the `-MapPath` by reflecting the
  map's path under `__ExternalActors__/` in the same Content mount.
- **Class name**: timestamped per run (`UCk_AutoTestProbeLockTolerance<TS>`).
  Avoids the AS class-registration collision pattern documented in
  `Plugins/CkFoundation/Source/CkAngelscriptGenerator/CLAUDE.md` —
  re-using a name within the same editor session can cause the new class
  registration to silently fail when stale `EntitySpawnParams.as` entries
  from earlier sessions remain on disk.

## Runtime artifacts

The probe generates these during a run:

```
<TestSourceDir>/_probe_lock_tolerance.as          ← the dropped probe source
Saved/AutoTestProbes/lock_tolerance.json          ← sidecar with pre-state
```

The probe `.as` lives in the AS source tree but is removed by the restore
script. The sidecar is under `Saved/` which is universally gitignored for
Unreal projects, so no .gitignore additions needed.

For projects that want stricter protection, add to `.gitignore`:

```gitignore
# AutoTest populator probes — runtime artifacts
**/_probe_lock_tolerance.as
```

## Full cleanup

The restore script removes the probe `.as` + sidecar. For a complete reset
to pre-probe disk state (so `git status` shows nothing left over from the
probe run), you also need:

1. **Restart the editor.** On startup, AS does a fresh disk-scan compile; the
   probe class is gone; the wrapper generator re-emits without its wrapper;
   the populator's first sync orphan-removes the placed wrapper + deletes its
   external `.uasset` via `FPackageSourceControlHelper::Delete`.
2. **Optional `git checkout -- <MapPath>`** to discard the orphan-remove's
   `.umap` save. The orphan-remove pass IS a map mutation, so the populator's
   standard save path runs and the `.umap` does change in that case —
   expected, NOT a regression. Discarding gets you back to bit-identical
   to HEAD.

The contrast between "add path doesn't touch `.umap`" (what we're proving)
and "remove path does touch `.umap`" (expected behavior for level mutations)
is itself a useful demonstration of the populator's design.

## Editor lifecycle gotchas

Same conventions as `CkAuto/SelfHealProbes/`:

- **Editor binary is `<ProjectName>Editor.exe`** under `<ProjectRoot>/Binaries/Win64/`,
  not the generic `UnrealEditor.exe`.
- **Editor-running check** uses an exclusive write-lock probe against
  `Saved/Logs/<ProjectName>*.log`.
- **Probe lifecycle**: editor MUST be running. The probe refuses if no log
  lock is detected.

## When to extend this suite

A new probe is warranted when:

1. A new populator code path lands and you want end-to-end coverage for it
   that's harder to reach via the C++ unit tests.
2. A user-visible failure mode is reported — write the probe first, then fix.

For per-method correctness (e.g., `Predict_Delta` logic, hash-of-external
behavior, single function semantics), prefer C++ unit tests
(`Plugins/CkTests/Source/CkTests/Private/UnitTests/`) — they're cheaper to
run and don't require an editor.

---

## Empirical baseline — verified 2026-05-14

Four runs across two save paths (populator + editor UI) and three different
maps. All PASS. Recorded here as a "this is what success looks like in
practice" baseline for future readers.

### 1. AutoTests_BB_MAP — populator path, real teammate-held LFS lock

The strongest single-data-point demonstration. `Saad K` was holding the
LFS lock on the BB AutoTests map during the entire run (lock ID
`38781955`). Probe ran via `_probe_lock_tolerance.bat`, populator's
post-AS-compile sync spawned the wrapper.

| Metric | Pre | Post |
|---|---|---|
| `.umap` SHA-256 | `4D757597160A3AAD6DC30D145A43925AA083E85795D59A0F2137564238FF1EF1` | `4D757597160A3AAD6DC30D145A43925AA083E85795D59A0F2137564238FF1EF1` |
| `.umap` size | 9012 bytes | 9012 bytes |
| `.umap` `IsReadOnly` | True (locked by teammate) | True (still locked) |
| External-actor count | 68 | 69 |
| Populator log | — | `1 spawned, 0 removed, 0 relabeled, 68 already present. Auto-saved.` |

`.umap` byte-identical under an active teammate LFS lock. The OFPA-aware
save path saved only the new external `.uasset`.

### 2. AutoTests_CkTests_Level — populator path, read-only without lock

Same probe, second `UCkAutoTestMapConfig`. Map was `IsReadOnly: True`
but no LFS lock holder.

| Metric | Pre | Post |
|---|---|---|
| `.umap` SHA-256 | `5F4E2DB00BBD10216D6A5B58E02B0E2BA9DE579FB6480F8C011C8BB8A358A32A` | `5F4E2DB00BBD10216D6A5B58E02B0E2BA9DE579FB6480F8C011C8BB8A358A32A` |
| `.umap` size | 9045 bytes | 9045 bytes |
| External-actor count | 171 | 172 |
| Populator log | — | `1 spawned, 0 removed, 0 relabeled, 168 already present. Auto-saved.` |

`.umap` byte-identical. Generalizes the result to a second
populator-config — same code path, same outcome.

### 3. Test_BB_MAP — editor UI flow (drag actor + Ctrl+S)

Fresh OFPA-enabled scratch map. Manual demonstration: drop an actor from
the Place Actors panel, save with Ctrl+S.

| Metric | Pre | Post |
|---|---|---|
| `.umap` SHA-256 | `5560388BE5F2A77BD2748B801B2AB3623D9BEF9BF21368ED8E3DAEF091375E58` | `5560388BE5F2A77BD2748B801B2AB3623D9BEF9BF21368ED8E3DAEF091375E58` |
| `.umap` size | 33944 bytes | 33944 bytes |
| `.umap` LastWriteTime | 2026-05-14 22:06:36 | 2026-05-14 22:06:36 (unchanged) |
| External-actor count | 15 | 15 (one file added, one swapped out by UE) |

`.umap` byte-identical AND OS LastWriteTime unchanged to the second.
UE's UI save flow did not touch the `.umap`.

### 4. AutoTests_CkTests_Level — editor UI flow (drag actor + Ctrl+S)

Same UI flow, tracked-in-HEAD map (cleaner git status signal than #3).

| Metric | Pre | Post |
|---|---|---|
| `.umap` SHA-256 | `B501E0005505A5AFCA4F290A64C4CBF1B5DAF944E093D57A1D0CEE591A39B2B5` | `B501E0005505A5AFCA4F290A64C4CBF1B5DAF944E093D57A1D0CEE591A39B2B5` |
| `.umap` size | 9017 bytes | 9017 bytes |
| `.umap` LastWriteTime | 2026-05-14 21:56:44 | 2026-05-14 21:56:44 (unchanged) |
| External-actor count | 171 | 172 |
| LFS lock holder | none | none |
| git status (post) | only `A` for the new external `.uasset` | |

### Key insight from runs 3 and 4

These two demonstrations contradicted the original PR 4 narrative.
The narrative claimed:

> "UE's standard editor save flow rewrites the `.umap` on every actor add
> to an OFPA level. The populator's PR 4 OFPA-aware save path is bespoke
> behavior the UI flow doesn't have."

The empirical result is the opposite: **UE's UI save flow ALREADY skips
the `.umap` write when only externals changed.** The standard
`FEditorFileUtils::SaveDirtyPackages` path is smarter than was assumed.
PR 4's "save only externals" behavior aligns the populator with what UE's
UI does natively; it's not adding new capability.

Why the original observation (PR 2's pre-PR-4 populator rewriting the
`.umap` on every test add) misled us: the pre-PR-4 populator was calling
`UEditorLoadingAndSavingUtils::SavePackages([level_package], bOnlyDirty=true)`
with the level package *explicitly* passed in. That forces a save of the
level package itself, regardless of whether the level had content-relevant
changes. The UI flow uses the higher-level `SaveDirtyPackages` API which
filters more carefully and skips the `.umap` when only externals are dirty.

This means OFPA's per-author parallel-add guarantee applies more broadly
than just our populator's flow — any artist or designer modifying actors
in an OFPA-enabled level via the editor UI also gets it for free.
