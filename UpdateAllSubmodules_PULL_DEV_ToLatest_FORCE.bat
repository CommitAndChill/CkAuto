set CMD=git checkout dev; git fetch origin dev; git reset --hard origin/dev
call %~dp0SubmodulesCustomCommand.bat %CMD%