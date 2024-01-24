set CMD=git checkout dev; git pull origin dev --ff-only
call %~dp0SubmodulesCustomCommand.bat %CMD%