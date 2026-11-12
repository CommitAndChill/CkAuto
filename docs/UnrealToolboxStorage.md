# Toolbox project storage options

Open UnrealToolbox for your project and select **Project Storage**, next to **Switch Engine**. The `s` shortcut opens its menu; Space also lists it.

1. Choose **Load current options** (or **Load options** in the configuration pane).
2. Use Tab to focus the configuration pane. Choose Editor build, Debug symbols, Project PCH, and Compress new output.
3. Choose **Apply choices** and review the displayed selections before confirming.
4. Build with Toolbox to use changed compiler/build settings. For standard Windows double-click launch, use Editor / Development.

Choices remain an unapplied draft until Apply. Each clone owns its configuration under `Saved/UnrealBuildTool`; colleagues' clones and machine-wide settings are not changed. No build or editor boot starts automatically. Close this project's editor and finish other operations first. Toolbox refuses a save if the relevant project or engine is busy, and cannot cancel midway through the configuration transaction.

| Option | Choices | Tradeoff |
| --- | --- | --- |
| Editor build | Unique / Shared | Unique owns project editor products. Shared requires compatible stock editor products; its first build may be large. |
| Debug symbols | None / Lean / Full | None disables native debug information and linker PDBs (no function names in callstacks). Lean retains engine compiler information and linker PDBs; Full retains full information. On a Shared clone the choice must match the engine's symbols policy (below). |
| Project PCH | Off / On | Off saves space at the cost of compilation speed. Engine PCHs remain enabled. |
| Compress new output | Off / On | Changes NTFS compression on every folder of the Binaries and Intermediate trees of the project and of each project plugin (folders under `Plugins/` holding a `.uplugin`, nested ones included), so files a build writes from now on are compressed. On a plugin-heavy project the plugin trees hold nearly all build output. Only folders change: existing files are not recompressed; run `compact /c /s` over a folder once to compress what is already there. With compression On, Apply creates a missing project or code-plugin output directory empty so the first build's files inherit compression. A plugin added after Apply shows compression as pending until you Apply again. |

## Engine symbols (one value per engine)

A Shared clone links the engine's own modules, so every Shared clone on one engine checkout must build them with the same debug settings, or each build recompiles and relinks the whole engine (about 4000 actions) and changes it for everyone. **Engine symbols** in Project Storage is that one value. It is stored in the engine's `Engine/Saved/UnrealBuildTool/BuildConfiguration.xml`, which UnrealBuildTool applies to every build on that engine, IDE builds and engine programs such as ShaderCompileWorker included.

| Engine symbols | Shared clones may use | Engine file |
| --- | --- | --- |
| Full (default) | Full (default) or Lean | no `DebugInfo` / `bNoLinkerDebugInfo` keys (UnrealBuildTool's default) |
| None | None | `DebugInfo=None`, `bNoLinkerDebugInfo=true` |

Which to choose (measured 2026-10-21 on BusterBlock): with Lean, project callstack frames keep function names but lose `file:line`; with None they become `UnknownFunction`, and under an engine set to None engine frames do too. An ensure or check still reports its own `file:line`, and AngelScript callstacks do not depend on PDBs. Keep the engine at Full with Shared clones on Full, plus Compress new output: compression saves far more than Lean (about 29 GB against about 5 GB per compressed clone, BusterBlock_alt2), and Lean costs project frames their `file:line`. Use Lean for extra space, and None only when nobody on that engine diagnoses native code. Switching to Shared moves a Debug symbols value the engine does not allow to its default (Full on a Full engine); None on Shared is always an explicit choice.

- Saving, measured on a BusterBlock engine worktree: an engine built at None writes no engine PDBs (39.6 GB at Full) and about 11.6 GB less intermediate output; each None clone saves about 21 GB of PDBs and 7 GB of intermediates. A rebuild does not delete the old PDBs; remove them separately.
- Choose the value under **Engine (every clone on it)** and **Apply engine symbols**. Only those two keys are written or removed; everything else in the file is kept. Nothing is inferred from a clone, and a clone's Apply never changes the engine file.
- Apply refuses a Shared clone whose Debug symbols the engine does not allow, and `--build` of such a clone stops with exit 83 before UnrealBuildTool runs. A Unique clone pins its own values and is unaffected.
- Switching rebuilds the engine on the next Shared build. Re-apply Debug symbols in every other Shared clone on that engine before building it; until then its toolbox builds stop with exit 83, and after another clone rebuilds the engine its test boots stop with exit 82 until it is rebuilt.
- Projects on that engine that do not set Debug symbols themselves (unmanaged clones, IDE-only projects) follow the engine policy.
- The toolbox refuses the setting while a machine or user `BuildConfiguration.xml` (ProgramData, AppData, LocalAppData, Documents) or an `UnrealBuildTool_*` environment variable sets debug keys, because those would override the engine file. An engine file with any other debug setting reads as **Unsupported**: Shared Apply and Shared builds are refused until Engine symbols is set.
- Not covered: a build started from an IDE does not run the toolbox check. Re-apply each Shared clone before building it from an IDE, and update the vendored `CkAuto` toolbox (v1.69 or later) in every project on the engine before switching to None.

**Restore previous** returns the original configuration bytes saved before first setup. It leaves existing build artifacts and compression intact, including the directory attributes Apply set; Apply with compression Off clears them. Changing profiles does not delete old PDBs, PCHs, build configurations or DDC; cleanup remains a separate operation. Saved configuration is not proof of a successful build or measured savings.

The backend is embedded in the executable; no separate PowerShell script installation is needed. Windows PowerShell is required. Apply currently requires a UE 5.7+ source engine exposing the verified DebugInfoMode API and project build rules that consume `CkCloneBuildOptions.json`. CkPlugins forks need the root editor-target integration and the matching CkFoundation PCH integration. Toolbox does not inject build rules into unsupported projects or alter tracked project source to enable them; Apply reports the incompatible target/engine/override instead.

The TUI and `--project-storage` (below) run the same embedded modules, with the same ownership/hash and restore contract. Do not import `CloneStorage.psm1` from FtxCatalyst source to change a clone: that skips the toolbox's locks and its editor-open refusal. Do not manually edit managed files or use the legacy ProjectStorage SetProfile while CloneStorage owns them. External termination or a power failure can still interrupt a multi-file save; mismatched state is refused and must be reconciled explicitly rather than overwritten.

## Command line (`--project-storage`, v1.80)

For agents and scripts. Every mode runs the same backend as the TUI, with the same locks and refusals. `--project` is required; `--engine-path` picks the engine (otherwise the engine saved for the project, then its `EngineAssociation`).

```
UnrealToolbox.exe --project-storage status  --project <dir> [--engine-path <engine>] [--output <log>]
UnrealToolbox.exe --project-storage plan    --project <dir> [--editor Shared|Unique] [--symbols None|Lean|Full] [--pch on|off] [--compress on|off]
UnrealToolbox.exe --project-storage apply   --project <dir> [the same options]
UnrealToolbox.exe --project-storage plan    --project <dir> --engine-symbols full|none
UnrealToolbox.exe --project-storage apply   --project <dir> --engine-symbols full|none --confirm-engine-wide
UnrealToolbox.exe --project-storage restore --project <dir>
```

- **status** reads the clone's options, compression state and the engine's symbols policy. It changes nothing. `Options` is the options file's content even when Project Storage does not manage it yet (`Configured: false`).
- **plan** is the review step: it runs the backend's `-WhatIf`, which performs every check an apply would and writes nothing. It prints the options an apply with the same flags would save (or the engine policy it would write), whether the project's editor is open (an apply is refused while it is), and the worktrees on the same engine with their profiles. A plan the backend would refuse exits 84, like the apply.
- **apply** saves the options. It builds them as the TUI's draft does: the clone's current options (its options file, else Unique / None / PCH Off / Compress On) with the given ones on top, and sends all four. Switching a clone to Shared without `--symbols` moves symbols the engine does not allow to the engine's default (Full on a Full engine), as the Editor build toggle does. A Shared clone whose symbols the engine no longer allows keeps them, and the apply is refused until `--symbols` names an allowed value.
- **`--engine-symbols`** changes the engine-wide policy, so it cannot be combined with the clone options; apply it, then apply the clone. The next Shared build rebuilds the engine, and every other Shared worktree on it whose Debug symbols the new policy does not allow stops with exit 83 until it is re-applied. Plan and apply both list those worktrees (`AFFECTED`). Apply requires `--confirm-engine-wide`; without it the apply exits 84 and writes nothing. An unchanged policy writes nothing and needs no confirmation.
- **restore** returns the original configuration bytes, as **Restore previous** does.

Output: one JSON object on stdout (`Outcome`, `ExitCode`, `Error`, `Applied`, `Configured`, `Options`, `PlannedOptions`, `CompressionStatus`, `CompressionErrors`, `EngineSymbols`, `PlannedEngineSymbols`, `EditorOpen`, `EngineWorktrees`, `WorktreeSearch`, `Notes`), a human summary on stderr, and both in `--output` when given.

| Exit | Meaning |
| --- | --- |
| 0 | Done (or, for plan/status, read). |
| 2, or CLI11's parse code (100 and up) | Bad arguments (a parse error, a missing `--project`, options that exclude each other), or `--project` / `--engine-path` does not name a project / engine. Nothing is printed on stdout. |
| 84 | Refused: nothing was saved. The editor is open (a resident warm server counts; `--warm-server stop` ends an idle one), the backend refused the options (for example Shared with symbols the engine does not allow, an externally edited managed file, an override in a machine `BuildConfiguration.xml`), or `--confirm-engine-wide` is missing. `Error` says which. |
| 85 | Busy: another build, test, or storage operation holds this project or engine. Retry when it ends; nothing was saved. |
| 86 | Error: the backend did not run or did not return a valid result, or a failed save could not be rolled back. Run `status` before retrying. |

**Which worktrees are listed.** The toolbox keeps no list of projects per engine, so it searches the worktrees of the project's git repository and the folders next to the project folder (each must hold one `.uproject`). A worktree counts as on this engine when its `Saved/UnrealToolbox/ScriptRegenStamp.json` (written by `--test`) names this engine. With no such file, the engine is the one a headless toolbox command would pick for it: its saved selection, then its `EngineAssociation`. A worktree elsewhere is not listed, nor is one moved to this engine and not tested through the toolbox since (its stamp still names the old engine): `WorktreeSearch` says where the search looked, so check others by hand before `--confirm-engine-wide`.
