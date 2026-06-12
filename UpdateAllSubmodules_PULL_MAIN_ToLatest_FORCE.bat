rem reset --hard does NOT remove ignored files — stale gitignored EntitySpawnParams
rem survive and wedge the AS self-heal at boot. clean -fX deletes only
rem UNTRACKED+IGNORED matches. Root repo first:
"C:\Program Files\Git\bin\git.exe" -C %~dp0.. clean -fX -- Script/Generated/*_EntitySpawnParams.as

set CMD=git checkout main; git fetch origin main; git reset --hard origin/main; git clean -fX -- Script/Generated/*_EntitySpawnParams.as
call %~dp0SubmodulesCustomCommand.bat %CMD%
