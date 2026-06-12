rem Stale gitignored EntitySpawnParams survive pulls forever (git no longer updates
rem them) and wedge the AS self-heal at boot. clean -fX deletes only UNTRACKED+IGNORED
rem matches, so tracked copies and real source are never touched. Root repo first:
"C:\Program Files\Git\bin\git.exe" -C %~dp0.. clean -fX -- Script/Generated/*_EntitySpawnParams.as

set CMD=git checkout main; git pull origin main --ff-only; git clean -fX -- Script/Generated/*_EntitySpawnParams.as
call %~dp0SubmodulesCustomCommand.bat %CMD%
