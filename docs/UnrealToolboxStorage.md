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
| Debug symbols | None / Lean / Full | None disables native debug information and requires Unique. Lean retains engine compiler information and linker PDBs; Full retains full information. |
| Project PCH | Off / On | Off saves space at the cost of compilation speed. Engine PCHs remain enabled. |
| Compress new output | Off / On | Changes NTFS compression on Binaries/Intermediate directories for future outputs. Existing files are not recompressed. Missing directories leave compression pending; retry Apply after they exist. |

**Restore previous** returns the original configuration bytes saved before first setup. It leaves existing build artifacts and compression intact. Changing profiles does not delete old PDBs, PCHs, build configurations or DDC; cleanup remains a separate operation. Saved configuration is not proof of a successful build or measured savings.

The backend is embedded in the executable; no separate PowerShell script installation is needed. Windows PowerShell is required. Apply currently requires a UE 5.7+ source engine exposing the verified DebugInfoMode API and project build rules that consume `CkCloneBuildOptions.json`. CkPlugins forks need the root editor-target integration and the matching CkFoundation PCH integration. Toolbox does not inject build rules into unsupported projects or alter tracked project source to enable them; Apply reports the incompatible target/engine/override instead.

The bundled modules retain the same ownership/hash and restore contract as CkAuto's CloneStorage script. Either interface can read the existing profile. Do not manually edit managed files or use the legacy ProjectStorage SetProfile while CloneStorage owns them. External termination or a power failure can still interrupt a multi-file save; mismatched state is refused and must be reconciled explicitly rather than overwritten.