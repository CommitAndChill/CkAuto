set CMD=git checkout main; git pull origin main --ff-only
call %~dp0SubmodulesCustomCommand.bat %CMD%