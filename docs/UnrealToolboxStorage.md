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

The bundled modules retain the same ownership/hash and restore contract as CkAuto's CloneStorage script. Either interface can read the existing profile. Do not manually edit managed files or use the legacy ProjectStorage SetProfile while CloneStorage owns them. External termination or a power failure can still interrupt a multi-file save; mismatched state is refused and must be reconciled explicitly rather than overwritten.