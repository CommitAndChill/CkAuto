# Project storage profiles

`ProjectStorage.ps1` manages a project-local Unreal Build Tool (UBT) debug-info setting and previews selected old build artifacts. It does not launch a build or delete files. Pass `-Project` as a project directory containing exactly one `.uproject`, or as that `.uproject` file. If omitted, it uses the parent of the `CkAuto` directory.

From `CkAuto` in Windows PowerShell 5.1 or PowerShell 7:

```powershell
.\ProjectStorage.ps1 -Project 'D:\Repos\BusterBlock'                     # Status (default)
.\ProjectStorage.ps1 -Project 'D:\Repos\BusterBlock' -Action SetProfile -Profile Lean -WhatIf
.\ProjectStorage.ps1 -Project 'D:\Repos\BusterBlock' -Action SetProfile -Profile Lean
.\ProjectStorage.ps1 -Project 'D:\Repos\BusterBlock' -Action SetProfile -Profile Full
.\ProjectStorage.ps1 -Project 'D:\Repos\BusterBlock' -Action SetProfile -Profile Default
.\ProjectStorage.ps1 -Project 'D:\Repos\BusterBlock' -Action PreviewCleanup -Configuration DebugGame | ConvertTo-Json -Depth 6
```

`SetProfile` requires `-Profile Lean`, `Full`, or `Default`. `-EngineRoot <path>` is available when the project's `EngineAssociation` cannot resolve the engine. Lean and Full require an available UE 5.7+ engine source tree with the supported project debug-info API. `-WhatIf` previews a profile change. The profile setting is written to `Saved/UnrealBuildTool/BuildConfiguration.xml`; a baseline and management state are kept beside it in `CkStorageProfile.json`. Check that the selected project's Git ignore rules exclude these `Saved` files before committing; the `CkAuto` repository's own `.gitignore` does not govern the project checkout.

Lean sets UBT `DebugInfo` to `EngineOnly` for project-owned rule paths. It retains engine and Windows link symbols; it does not promise a PDB-free build or a specific space saving. Full sets `DebugInfo` to `Full`. Default restores the exact original XML bytes, or removes the managed XML if none existed before profile selection. Restoration refuses to overwrite XML edited outside this command after selection. Profile selection writes only project-local XML and state; build outputs remain pending verification.

Status reports the selected profile, XML path, and `PendingBuildVerification` after a profile is set. Lean reports Development as the recommended build configuration; it does not enforce it. Run the next project build through `CkAuto/UnrealToolbox.exe` with `--project=<absolute-project-path>` and `--build --config=Development` when that configuration is appropriate. Existing command-line, environment, or target-rule overrides and Live Coding behavior can change the effective UBT setting. Project builds from the current executable, Visual Studio, and Rider can load this project-local XML when they use UBT, but their effective build actions have not been verified here. The next build may recompile code, and old artifacts remain until separately handled.

`PreviewCleanup` defaults to `DebugGame`; it also accepts `Debug`, `Test`, or `Shipping` through `-Configuration`. It reports exact candidate paths, reasons, counts, logical bytes, and the number of skipped reparse points. Candidates are generated files with recognized extensions under the project's or actual project plugins' `Intermediate/Build` configuration directories, or `Binaries` files explicitly decorated with `-<platform>-<configuration>` before the extension. It never offers undecorated Development files or broad folder deletion, and it does not follow junctions. There is no apply/delete action. Treat logical bytes as an inventory, not a guaranteed reclaimed-space figure.

Focused filesystem tests, with fixtures under the supplied work directory, run in either PowerShell edition:

```powershell
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'CkAuto-StorageTests'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ProjectStorageProfiles.ps1 -FixtureParent $fixtureRoot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ProjectCleanupPreview.ps1 -FixtureRoot $fixtureRoot
pwsh.exe -NoProfile -File .\tests\Test-ProjectStorageProfiles.ps1 -FixtureParent $fixtureRoot
pwsh.exe -NoProfile -File .\tests\Test-ProjectCleanupPreview.ps1 -FixtureRoot $fixtureRoot
```

Compression and shared PCH storage are separate future work.
