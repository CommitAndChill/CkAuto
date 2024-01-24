set CMD=git fetch origin main; git fetch . origin/main:dev
call %~dp0SubmodulesCustomCommand.bat %CMD%