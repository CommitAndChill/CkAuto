set CMD=git checkout main; git fetch origin main; git reset --hard origin/main
call %~dp0SubmodulesCustomCommand.bat %CMD%